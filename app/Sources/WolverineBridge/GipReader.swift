import CGipCore
import Darwin
import Foundation
import Synchronization
import XboxHID

/// Runs the GIP host core (src/core, libgipcore.a) on one dedicated thread. The core is not
/// thread-safe, so every gip_* call happens on that thread. Decoded input goes out as Xbox
/// Bluetooth input reports through `onReport`; rumble requests from other threads are queued
/// and sent between polls.
///
/// Lifecycle (Phase 4): the reader reopens the pad after a loss, restarts a session whose
/// handshake failed or stalled (backoff 10, 20, 40, 60 s), restarts it when a Hello arrives after
/// the handshake completed (pad reconnected to the receiver), and can release the USB device on
/// request so giptool or another USB reader can claim it.
final class GipReader: @unchecked Sendable {
    struct Stats: Sendable {
        var connected = false    // USB handle open
        var released = false     // USB device released on request (setReleased)
        var handshake: String?   // gip_auth_state_name of the current session; nil before it starts
        var handshakeRetries = 0 // sessions restarted by the handshake supervisor
        var inputs = 0           // on_state callbacks (0x20 input and 0x07 Guide)
        var reports = 0          // reports handed to onReport, including keep-alives
        var rumbleSent = 0, rumbleDropped = 0, rumbleFailed = 0
        var state = PadState()

        var ready: Bool { connected && handshake == "complete" }
    }

    /// Poll timeout, same as giptool. With 8 ms the security handshake did not complete
    /// (2026-11-27, receiver: 0/2 runs at 8 ms, 1/1 at 100 ms; cause unverified, possibly IN
    /// packets lost when a timed-out transfer is cancelled). Queued rumble therefore waits up to
    /// 100 ms while the pad is idle; during play 0x20 reports end each poll early.
    static let pollMilliseconds: Int32 = 100
    static let reopenMicroseconds: useconds_t = 500_000 // like giptool
    static let keepAlive: Duration = .milliseconds(100)
    /// Time a session may spend before its handshake completes. Each stall restart moves one step
    /// up; a completed handshake or a lost device resets it. With the receiver plugged in and the
    /// pad off, the handshake never completes, so the receiver is reopened at these intervals; the
    /// reopen is also what gives a pad switched on later its handshake (the core ignores a second
    /// Hello).
    static let handshakeTimeouts: [Duration] = [.seconds(10), .seconds(20), .seconds(40), .seconds(60)]

    private let vid: Int32, pid: Int32
    private let onLog: @Sendable (String) -> Void
    private let onReport: @Sendable (Data) -> Void
    private let onExit: @Sendable () -> Void
    private let stopFlag = Atomic<Bool>(false)
    private let releaseFlag = Atomic<Bool>(false)
    private let rumbleOn = Atomic<Bool>(true)
    private let pendingRumble = Mutex<[UInt8]?>(nil)
    private let stats = Mutex(Stats())

    // Reader-thread only.
    private var state = PadState()
    private var lastReport = ContinuousClock.now
    private var openedAt = ContinuousClock.now
    private var stallStep = 0
    private var helloAtComplete: Int32? // n_hello when this session's handshake completed

    init(
        vid: Int32, pid: Int32,
        onLog: @escaping @Sendable (String) -> Void,
        onReport: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) {
        self.vid = vid
        self.pid = pid
        self.onLog = onLog
        self.onReport = onReport
        self.onExit = onExit
    }

    var snapshot: Stats { stats.withLock { $0 } }

    func start() {
        let t = Thread { [self] in run() }
        t.name = "gip-reader"
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Asks the reader to stop. `onExit` runs on the reader thread after it has sent a neutral
    /// report and released the USB device.
    func stop() { stopFlag.store(true, ordering: .relaxed) }

    /// true: close the USB device (the pad re-enumerates, ~2 s) and keep sending neutral reports
    /// until false, which claims it again.
    func setReleased(_ released: Bool) { releaseFlag.store(released, ordering: .relaxed) }

    /// Rumble requests are forwarded only while enabled (CLI --no-rumble, menu toggle).
    var rumbleEnabled: Bool {
        get { rumbleOn.load(ordering: .relaxed) }
        set { rumbleOn.store(newValue, ordering: .relaxed) }
    }

    /// Queues the 8 bytes of Xbox Bluetooth output report 3 (mask, LT, RT, strong, weak,
    /// duration, delay, loop count). A newer request replaces one that was not sent yet.
    func rumble(_ bytes: [UInt8]) {
        precondition(bytes.count == 8)
        guard rumbleEnabled else { return }
        let replaced = pendingRumble.withLock { p in
            defer { p = bytes }
            return p != nil
        }
        if replaced { stats.withLock { $0.rumbleDropped += 1 } }
    }

    // MARK: - Reader thread

    private func run() {
        var cfg = gip_config_t()
        gip_config_default(&cfg)
        cfg.vid = vid
        cfg.pid = pid
        var cb = gip_callbacks_t()
        cb.user = Unmanaged.passUnretained(self).toOpaque()
        cb.on_state = { user, _, s, _, _ in
            guard let user, let s else { return }
            Unmanaged<GipReader>.fromOpaque(user).takeUnretainedValue().handleState(s.pointee)
        }
        cb.on_log = { user, line in
            guard let user, let line else { return }
            Unmanaged<GipReader>.fromOpaque(user).takeUnretainedValue().onLog(String(cString: line))
        }
        guard let d = gip_new(&cfg, &cb) else {
            onLog("libusb_init failed")
            onExit()
            return
        }
        let id = String(format: "%04x:%04x", vid, pid)
        var lastOpenError = 0 // logs each distinct open failure once
        var released = false

        while !stopFlag.load(ordering: .relaxed) {
            if releaseFlag.load(ordering: .relaxed) {
                if !released {
                    released = true
                    if gip_is_open(d) != 0 { gip_close(d) }
                    setConnected(false)
                    stats.withLock { $0.released = true; $0.handshake = nil }
                    onLog("released \(id); giptool or another reader can claim it")
                }
                if pendingRumble.withLock({ p in defer { p = nil }; return p }) != nil {
                    stats.withLock { $0.rumbleDropped += 1 }
                }
                usleep(UInt32(Self.pollMilliseconds) * 1000)
                if ContinuousClock.now - lastReport >= Self.keepAlive { emit() }
                continue
            }
            if released {
                released = false
                lastOpenError = 0
                stallStep = 0
                stats.withLock { $0.released = false }
                onLog("resumed; claiming \(id)")
            }

            if gip_is_open(d) == 0 {
                let r = Int(gip_open(d))
                if r != GIP_OK {
                    if r != lastOpenError {
                        lastOpenError = r
                        // NO_IFACE and CLAIM failures were already logged by the core.
                        if r == GIP_ERR_NOT_FOUND {
                            onLog("waiting for \(id) (another reader such as giptool may hold it)")
                        } else {
                            onLog("open \(id) failed (\(r)); retrying every 0.5 s")
                        }
                    }
                    usleep(Self.reopenMicroseconds)
                    continue
                }
                lastOpenError = 0
                openedAt = .now
                helloAtComplete = nil
                setConnected(true)
            }

            if Int(gip_poll(d, Self.pollMilliseconds)) == GIP_ERR_LOST {
                // The core logged "device lost" and closed the handle. Release every control so
                // nothing stays held while the pad reconnects.
                setConnected(false)
                stats.withLock { $0.handshake = nil }
                stallStep = 0
                usleep(Self.reopenMicroseconds)
                continue
            }
            if !superviseHandshake(d) { continue }

            if let r = pendingRumble.withLock({ p in defer { p = nil }; return p }) {
                sendRumble(d, r)
            }
            if ContinuousClock.now - lastReport >= Self.keepAlive { emit() }
        }

        gip_free(d) // releases the interface; macOS then re-enumerates the pad (~2 s)
        setConnected(false)
        onExit()
    }

    /// Restarts the session when its handshake failed, stalled, or a Hello arrived after it
    /// completed. Returns false when it closed the device.
    private func superviseHandshake(_ d: OpaquePointer) -> Bool {
        var st = gip_stats_t()
        gip_get_stats(d, &st)
        let auth = st.auth.map { String(cString: $0) }
        stats.withLock { $0.handshake = auth }
        if auth == "complete" {
            guard let hello = helloAtComplete else {
                helloAtComplete = st.n_hello
                stallStep = 0
                onLog(String(format: "handshake complete after %.1f s", seconds(ContinuousClock.now - openedAt)))
                return true
            }
            if st.n_hello > hello {
                return restart(d, "Hello after the handshake (pad reconnected?)")
            }
            return true
        }
        if auth == "failed" { return restart(d, "handshake failed") }
        let timeout = Self.handshakeTimeouts[stallStep]
        if ContinuousClock.now - openedAt >= timeout {
            stallStep = min(stallStep + 1, Self.handshakeTimeouts.count - 1)
            let next = Self.handshakeTimeouts[stallStep]
            return restart(d, String(format: "handshake not complete after %.0f s (next timeout %.0f s)",
                                     seconds(timeout), seconds(next)))
        }
        return true
    }

    private func restart(_ d: OpaquePointer, _ reason: String) -> Bool {
        gip_close(d) // macOS re-enumerates the pad (~2 s); the main loop reopens it
        setConnected(false)
        let n = stats.withLock { s in
            s.handshake = nil
            s.handshakeRetries += 1
            return s.handshakeRetries
        }
        onLog("\(reason); reopening (retry \(n))")
        usleep(Self.reopenMicroseconds)
        return false
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func sendRumble(_ d: OpaquePointer, _ b: [UInt8]) {
        let r = Int(gip_rumble(d, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]))
        stats.withLock { s in
            switch r {
            case GIP_OK: s.rumbleSent += 1
            case GIP_ERR_NOT_READY: s.rumbleDropped += 1
            default: s.rumbleFailed += 1
            }
        }
    }

    private func setConnected(_ connected: Bool) {
        let was = stats.withLock { s in
            defer { s.connected = connected }
            return s.connected
        }
        if !connected {
            state = PadState()
            if was { emit() }
        }
    }

    private func handleState(_ s: gip_state_t) {
        state = Self.padState(s)
        stats.withLock { $0.inputs += 1 }
        emit()
    }

    private func emit() {
        lastReport = .now
        let state = state
        stats.withLock { s in
            s.reports += 1
            s.state = state
        }
        onReport(state.bluetoothInputReport())
    }

    static let buttonMap: [(Int32, Button)] = [
        (GIP_BTN_A, .a), (GIP_BTN_B, .b), (GIP_BTN_X, .x), (GIP_BTN_Y, .y),
        (GIP_BTN_LB, .lb), (GIP_BTN_RB, .rb), (GIP_BTN_VIEW, .view), (GIP_BTN_MENU, .menu),
        (GIP_BTN_LS, .ls), (GIP_BTN_RS, .rs),
        (GIP_BTN_DU, .dpadUp), (GIP_BTN_DD, .dpadDown), (GIP_BTN_DL, .dpadLeft), (GIP_BTN_DR, .dpadRight),
    ]

    /// GIP sticks are s16 with Y up positive, and triggers are 0..1023. PadState uses -1...1
    /// (Y up positive) and 0...1; its encoder flips Y for HID and produces 0..65535 and 0..1023.
    static func padState(_ s: gip_state_t) -> PadState {
        func axis(_ v: Int16) -> Double { max(-1, Double(v) / 32767) }
        func trigger(_ v: UInt16) -> Double { Double(min(v, 1023)) / 1023 }
        var p = PadState()
        p.leftX = axis(s.lx)
        p.leftY = axis(s.ly)
        p.rightX = axis(s.rx)
        p.rightY = axis(s.ry)
        p.leftTrigger = trigger(s.lt)
        p.rightTrigger = trigger(s.rt)
        for (bit, button) in buttonMap where s.buttons & UInt16(bit) != 0 { p.buttons.insert(button) }
        if s.guide != 0 { p.buttons.insert(.guide) }
        return p
    }
}
