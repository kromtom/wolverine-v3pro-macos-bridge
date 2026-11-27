import CoreHID
import Foundation
import Synchronization
import XboxHID

/// The app's bundle ID. scripts/build-app.sh writes it into Info.plist from the provisioning
/// profile (or BUNDLE_ID); the fallback applies only to a binary run outside the bundle.
let appBundleID = Bundle.main.bundleIdentifier ?? "WolverineBridge"

/// Bridge settings. The CLI sets them from flags; the menu bar app uses the defaults.
struct BridgeOptions: Sendable {
    var productID: UInt32 = 0x0B13
    var versionNumber: UInt64 = 0x0513
    var transport: HIDDeviceTransport = .bluetooth
    var vid: Int32 = 0x1532
    var pid: Int32 = 0x0A3F
    var rumble = true
    var seconds: Double?
    var verbose = false
}

/// One virtual Xbox Bluetooth pad fed by one GipReader: creates the HIDVirtualDevice, starts the
/// reader, and dispatches its reports until the reader exits. Shared by the CLI and the menu bar app.
final class BridgeSession: Sendable {
    struct PumpStats: Sendable { var sent = 0, failed = 0 }

    let options: BridgeOptions
    let reader: GipReader
    private let device: HIDVirtualDevice
    private let reports: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation
    private let pump = Mutex(PumpStats())
    private let log: @Sendable (String) -> Void

    /// nil when HIDVirtualDevice(properties:) fails (missing entitlement, or not run from the
    /// signed bundle).
    init?(options: BridgeOptions, log: @escaping @Sendable (String) -> Void) {
        let properties = HIDVirtualDevice.Properties(
            descriptor: XboxBluetooth.descriptor,
            vendorID: XboxBluetooth.vendorID,
            productID: options.productID,
            transport: options.transport,
            product: "Xbox Wireless Controller",
            manufacturer: "Microsoft",
            versionNumber: options.versionNumber,
            serialNumber: "WOLVERINE-V3-PRO",
            uniqueID: "\(appBundleID).bridge"
        )
        guard let device = HIDVirtualDevice(properties: properties) else { return nil }
        self.options = options
        self.device = device
        self.log = log
        let (reports, sink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(64))
        self.reports = reports
        self.sink = sink
        reader = GipReader(
            vid: options.vid, pid: options.pid,
            onLog: log,
            onReport: { sink.yield($0) },
            onExit: { sink.finish() }
        )
        reader.rumbleEnabled = options.rumble
    }

    static let deviceError = """
        HIDVirtualDevice(properties:) returned nil.
        Check the signature: codesign -d --entitlements - <app> must list
        com.apple.developer.hid.virtual.device, and the app must run from its signed bundle.
        """

    var pumpStats: PumpStats { pump.withLock { $0 } }

    /// Activates the virtual device and starts the reader.
    func start() async {
        await device.activate(delegate: BridgeDelegate(reader: reader, verbose: options.verbose, log: log))
        log(String(format: "virtual device active: %04X:%04X version 0x%llx transport \(options.transport); rumble %@",
                   XboxBluetooth.vendorID, options.productID, options.versionNumber, options.rumble ? "on" : "off"))
        // Send a neutral report so the device has a defined state before the pad connects.
        sink.yield(PadState().bluetoothInputReport())
        reader.start()
    }

    /// Dispatches reports until the reader exits (after `reader.stop()`).
    func run() async {
        var last: Data?
        for await report in reports {
            do {
                try await device.dispatchInputReport(data: report, timestamp: SuspendingClock.now)
                pump.withLock { $0.sent += 1 }
                if options.verbose && report != last { log("report \(Self.hex(report))") }
            } catch {
                let failed = pump.withLock { p in
                    p.failed += 1
                    return p.failed
                }
                if failed == 1 || failed % 500 == 0 { log("dispatchInputReport failed (\(failed)x): \(error)") }
            }
            last = report
        }
    }

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

/// Forwards host rumble (output report 3) to the pad; logs other host requests.
final class BridgeDelegate: HIDVirtualDeviceDelegate {
    let reader: GipReader
    let verbose: Bool
    let log: @Sendable (String) -> Void
    private let loggedFirstRumble = Atomic<Bool>(false)

    init(reader: GipReader, verbose: Bool, log: @escaping @Sendable (String) -> Void) {
        self.reader = reader
        self.verbose = verbose
        self.log = log
    }

    func hidVirtualDevice(
        _ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
        id: HIDReportID?, data: Data
    ) async throws {
        var bytes = [UInt8](data)
        // Accept the payload with or without a leading report ID byte.
        if bytes.count == 9 && bytes[0] == XboxBluetooth.rumbleReportID { bytes.removeFirst() }
        let isRumble = type == .output && bytes.count == 8
            && (id?.rawValue ?? XboxBluetooth.rumbleReportID) == XboxBluetooth.rumbleReportID
        if isRumble {
            if !loggedFirstRumble.exchange(true, ordering: .relaxed) || verbose {
                log("rumble \(BridgeSession.hex(bytes))\(reader.rumbleEnabled ? "" : " (ignored, rumble off)")")
            }
            reader.rumble(bytes)
            return
        }
        log("set report type=\(type) id=\(id.map { "\($0.rawValue)" } ?? "none") data=\(BridgeSession.hex(data))")
        throw HIDDeviceError.unsupported
    }

    func hidVirtualDevice(
        _ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
        id: HIDReportID?, maxSize: Int
    ) async throws -> Data {
        if type == .input, id?.rawValue ?? XboxBluetooth.inputReportID == XboxBluetooth.inputReportID {
            return reader.snapshot.state.bluetoothInputReport()
        }
        log("get report type=\(type) id=\(id.map { "\($0.rawValue)" } ?? "none") maxSize=\(maxSize)")
        throw HIDDeviceError.unsupported
    }
}
