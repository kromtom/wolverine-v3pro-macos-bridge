import CoreHID
import Darwin
import Foundation
import XboxHID

/// Terminal mode (`--cli`): the Phase 3 bridge with its flags and live status line. Logs go to
/// stderr. The menu bar app (MenuApp.swift) runs the same BridgeSession.
enum CLI {
    static let usage = """
    usage: WolverineBridge                 menu bar app (default)
           WolverineBridge --cli [options] terminal mode
      --identity series|ones  Impersonate 045E:0B13 (Xbox Series, default) or 045E:02FD (One S)
      --version 0xNNNN        HID version number of the virtual device (default 0x0513)
      --transport bluetooth|usb|virtual   Reported transport (default bluetooth)
      --usb-pid 0xNNNN        Wolverine USB product ID (default 0x0a3f; vendor 0x1532)
      --no-rumble             Ignore rumble requests from the host
      --seconds N             Exit after N seconds
      --verbose               Log every report sent and every rumble request
    """

    static func parse(_ args: [String]) -> BridgeOptions {
        var o = BridgeOptions()
        var it = args.makeIterator()
        func value(_ flag: String) -> String {
            guard let v = it.next() else { fail("\(flag) needs a value") }
            return v
        }
        func hex(_ flag: String) -> UInt64 {
            let v = value(flag)
            let s = v.hasPrefix("0x") || v.hasPrefix("0X") ? String(v.dropFirst(2)) : v
            guard let n = UInt64(s, radix: 16) else { fail("\(flag): bad hex value \(v)") }
            return n
        }
        while let a = it.next() {
            switch a {
            case "--cli": break
            case "--identity":
                switch value(a) {
                case "series": o.productID = 0x0B13
                case "ones": o.productID = 0x02FD
                case let v: fail("--identity: unknown value \(v)")
                }
            case "--version": o.versionNumber = hex(a)
            case "--transport":
                switch value(a) {
                case "bluetooth": o.transport = .bluetooth
                case "usb": o.transport = .usb
                case "virtual": o.transport = .virtual
                case let v: fail("--transport: unknown value \(v)")
                }
            case "--usb-pid": o.pid = Int32(truncatingIfNeeded: hex(a) & 0xFFFF)
            case "--no-rumble": o.rumble = false
            case "--seconds":
                guard let n = Double(value(a)), n > 0 else { fail("--seconds needs a positive number") }
                o.seconds = n
            case "--verbose": o.verbose = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default: fail("unknown option \(a)\n\(usage)")
            }
        }
        return o
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }

    static let statusLine = isatty(STDERR_FILENO) != 0

    @Sendable static func log(_ message: String) {
        // Clear the status line first so log lines do not mix with it.
        let line = (statusLine ? "\r\u{1B}[K" : "") + message + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func run(_ o: BridgeOptions) async -> Never {
        guard let session = BridgeSession(options: o, log: log) else { fail(BridgeSession.deviceError) }
        let reader = session.reader
        await session.start()

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { reader.stop() }
            src.resume()
            sources.append(src)
        }
        if let limit = o.seconds {
            Task {
                try? await Task.sleep(for: .seconds(limit))
                reader.stop()
            }
        }
        let status = statusLine ? Task {
            while !Task.isCancelled {
                printStatus(reader.snapshot)
                try? await Task.sleep(for: .milliseconds(100))
            }
        } : nil

        await session.run()
        status?.cancel()
        _ = sources
        let s = reader.snapshot, p = session.pumpStats
        log("stopped: \(s.inputs) pad updates, \(p.sent) reports sent (\(p.failed) failed), "
            + "rumble \(s.rumbleSent) sent / \(s.rumbleDropped) dropped / \(s.rumbleFailed) failed, "
            + "\(s.handshakeRetries) handshake retries")
        exit(0)
    }

    static func printStatus(_ s: GipReader.Stats) {
        let p = s.state
        let names = Button.allCases.filter { p.buttons.contains($0) }.map { "\($0)" }.joined(separator: " ")
        let line = String(
            format: "\r\u{1B}[K%@ in %d rep %d rmb %d  L(%+.2f,%+.2f) R(%+.2f,%+.2f) LT %.2f RT %.2f  %@",
            s.ready ? "pad" : s.connected ? "hs." : "---", s.inputs, s.reports, s.rumbleSent,
            p.leftX, p.leftY, p.rightX, p.rightY, p.leftTrigger, p.rightTrigger, names
        )
        FileHandle.standardError.write(Data(line.utf8))
    }
}
