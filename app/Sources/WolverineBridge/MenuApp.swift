import AppKit
import Foundation
import os
import ServiceManagement
import SwiftUI
import Synchronization

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--cli") || args.contains("--help") || args.contains("-h") {
            let options = CLI.parse(args)
            Task { await CLI.run(options) }
            dispatchMain()
        }
        BridgeApp.main()
    }
}

/// Menu bar app (LSUIElement): bridges on launch, shows status, and offers Release USB, Rumble,
/// Start at login, and a log window.
struct BridgeApp: App {
    @State private var model = BridgeModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.iconName)
        }
        Window("WolverineBridge Log", id: LogView.windowID) {
            LogView(model: model)
        }
        .defaultSize(width: 640, height: 360)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Last log lines for the log window, plus os_log (Console.app, subsystem = the app's bundle ID).
/// A line equal to the previous one (such as the core's claim failure every 0.5 s while another
/// reader holds the pad) updates that entry's time and repeat count instead of adding a line.
final class LogBuffer: Sendable {
    static let capacity = 20
    private struct Entry { var time: Date, message: String, count: Int }
    private let entries = Mutex<[Entry]>([])
    private let logger = Logger(subsystem: appBundleID, category: "bridge")

    func append(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        entries.withLock { e in
            if let last = e.indices.last, e[last].message == message {
                e[last].time = .now
                e[last].count += 1
                return
            }
            e.append(Entry(time: .now, message: message, count: 1))
            if e.count > Self.capacity { e.removeFirst(e.count - Self.capacity) }
        }
    }

    var snapshot: [String] {
        entries.withLock { e in
            e.map { "\($0.time.formatted(date: .omitted, time: .standard))  \($0.message)\($0.count > 1 ? " (\($0.count)x)" : "")" }
        }
    }
}

@MainActor @Observable
final class BridgeModel {
    private(set) var stats = GipReader.Stats()
    private(set) var logLines: [String] = []
    private(set) var deviceError: String?
    private(set) var loginStatus = SMAppService.mainApp.status
    private(set) var released = false
    private(set) var rumble = true

    private let log = LogBuffer()
    private var session: BridgeSession?
    private var stopped = false // set when the session's report pump has ended

    /// Start at login only from an installed copy: `make bridge` deletes and rebuilds build/.
    let installed: Bool = {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }()

    init() {
        if Self.anotherInstanceRunning() {
            let alert = NSAlert()
            alert.messageText = "WolverineBridge is already running"
            alert.informativeText = "Only one bridge can claim the controller. Use the running copy's menu bar icon."
            alert.runModal()
            exit(0)
        }
        let log = log
        guard let session = BridgeSession(options: BridgeOptions(), log: { log.append($0) }) else {
            deviceError = "Virtual device unavailable (signature or entitlement)"
            log.append(BridgeSession.deviceError.replacingOccurrences(of: "\n", with: " "))
            logLines = log.snapshot
            return
        }
        self.session = session
        Task { [weak self] in
            await session.start()
            await session.run()
            self?.stopped = true
        }
        Task { [weak self] in
            while let self {
                self.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func anotherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Assigns only changed values: @Observable notifies on every assignment, and each notice
    /// rebuilds the menu.
    func refresh() {
        if let session {
            let s = session.reader.snapshot
            if s != stats { stats = s }
        }
        let lines = log.snapshot
        if lines != logLines { logLines = lines }
        let status = SMAppService.mainApp.status
        if status != loginStatus { loginStatus = status }
    }

    var iconName: String {
        if deviceError != nil { return "exclamationmark.triangle" }
        if stats.released { return "pause.circle" }
        return stats.ready ? "gamecontroller.fill" : "gamecontroller"
    }

    var statusText: String {
        if let deviceError { return deviceError }
        if stats.released { return "Released: giptool or another reader can claim the pad" }
        if !stats.connected { return "Waiting for Wolverine (1532:0a3f)" }
        return stats.ready ? "Connected: handshake complete" : "Connected: handshake \(stats.handshake ?? "starting")"
    }

    func setReleased(_ on: Bool) {
        released = on
        session?.reader.setReleased(on)
    }

    func setRumble(_ on: Bool) {
        rumble = on
        session?.reader.rumbleEnabled = on
        log.append("rumble \(on ? "on" : "off")")
    }

    func setStartAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log.append("start at login \(on ? "registered" : "unregistered") (\(Bundle.main.bundlePath))")
        } catch {
            log.append("start at login: \(error.localizedDescription)")
        }
        refresh()
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.snapshot.joined(separator: "\n"), forType: .string)
    }

    /// Stops the reader (neutral report, USB released) before quitting; gives up after 3 s.
    func quit() {
        guard let session else { NSApplication.shared.terminate(nil); return }
        session.reader.stop()
        Task {
            for _ in 0..<30 where !stopped { try? await Task.sleep(for: .milliseconds(100)) }
            NSApplication.shared.terminate(nil)
        }
    }
}

struct MenuContent: View {
    let model: BridgeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = model.stats
        Text(model.statusText)
        Text("Handshake: \(s.handshake ?? "-"), \(s.handshakeRetries) retries")
        Text("Input: \(s.inputs) pad updates, \(s.reports) reports")
        Text("Rumble: \(s.rumbleSent) sent, \(s.rumbleDropped) dropped, \(s.rumbleFailed) failed")
        Divider()
        Toggle("Release USB Device", isOn: Binding(get: { model.released }, set: { model.setReleased($0) }))
            .disabled(model.deviceError != nil)
        Toggle("Rumble", isOn: Binding(get: { model.rumble }, set: { model.setRumble($0) }))
            .disabled(model.deviceError != nil)
        Toggle("Start at Login", isOn: Binding(
            get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
            set: { model.setStartAtLogin($0) }
        ))
        .disabled(!model.installed)
        if !model.installed {
            Text("Start at Login needs ~/Applications (make install-bridge)")
        } else if model.loginStatus == .requiresApproval {
            Button("Approve in Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
        }
        Button("Show Log…") {
            NSApp.activate() // LSUIElement app: bring the window to the front
            openWindow(id: LogView.windowID)
        }
        Divider()
        Button("About WolverineBridge…") {
            NSWorkspace.shared.open(URL(string: "https://github.com/kromtom/wolverine-v3pro-macos-bridge")!)
        }
        Button("Quit WolverineBridge") { model.quit() }
            .keyboardShortcut("q")
    }
}

/// Live log, newest first. A window instead of a submenu: a submenu closes on each menu rebuild.
struct LogView: View {
    static let windowID = "log"
    let model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(model.logLines.reversed().joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            HStack {
                Spacer()
                Button("Copy Log") { model.copyLog() }
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 200)
    }
}
