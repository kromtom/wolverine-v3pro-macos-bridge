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
/// Start at login, and a log window. The status item and its menu are AppKit (StatusMenu); the
/// SwiftUI App remains for its lifecycle and main menu (Edit commands such as Copy in the log window).
struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenu(model: BridgeModel())
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
    /// updates the menu and the log window.
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

/// The status item and its menu. Items are created once and update() changes their titles and
/// states in place. SwiftUI's MenuBarExtra replaced every item on each model change, which blanked
/// labels in an open menu; with in-place updates the open menu stays drawn and live.
@MainActor
final class StatusMenu: NSObject {
    private let model: BridgeModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let status = NSMenuItem.info()
    private let handshake = NSMenuItem.info()
    private let input = NSMenuItem.info()
    private let rumbleStats = NSMenuItem.info()
    private let loginNote = NSMenuItem.info("Start at Login needs ~/Applications (make install-bridge)")
    private lazy var release = item("Release USB Device", #selector(toggleRelease))
    private lazy var rumble = item("Rumble", #selector(toggleRumble))
    private lazy var login = item("Start at Login", #selector(toggleLogin))
    private lazy var approve = item("Approve in Login Items Settings…", #selector(approveLogin))
    private var iconName: String?
    private var logWindow: NSWindow?

    init(model: BridgeModel) {
        self.model = model
        super.init()
        menu.autoenablesItems = false
        for i in [status, handshake, input, rumbleStats, .separator(), release, rumble, login, loginNote, approve,
                  item("Show Log…", #selector(showLog)), .separator(),
                  item("About WolverineBridge…", #selector(about)),
                  item("Quit WolverineBridge", #selector(quit), key: "q")] {
            menu.addItem(i)
        }
        statusItem.menu = menu
        observe()
    }

    /// Runs update() now and again after each change of a model property it read.
    private func observe() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() } // onChange runs before the new value is stored
        }
    }

    private func update() {
        let s = model.stats
        if model.iconName != iconName {
            iconName = model.iconName
            statusItem.button?.image = NSImage(systemSymbolName: model.iconName, accessibilityDescription: "WolverineBridge")
        }
        status.setTitle(model.statusText)
        handshake.setTitle("Handshake: \(s.handshake ?? "-"), \(s.handshakeRetries) retries")
        input.setTitle("Input: \(s.inputs) pad updates, \(s.reports) reports")
        rumbleStats.setTitle("Rumble: \(s.rumbleSent) sent, \(s.rumbleDropped) dropped, \(s.rumbleFailed) failed")
        let deviceOK = model.deviceError == nil
        release.setState(model.released, enabled: deviceOK)
        rumble.setState(model.rumble, enabled: deviceOK)
        login.setState(model.loginStatus == .enabled || model.loginStatus == .requiresApproval, enabled: model.installed)
        loginNote.isHidden = model.installed
        approve.isHidden = !(model.installed && model.loginStatus == .requiresApproval)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleRelease() { model.setReleased(!model.released) }
    @objc private func toggleRumble() { model.setRumble(!model.rumble) }
    @objc private func toggleLogin() { model.setStartAtLogin(login.state != .on) }
    @objc private func approveLogin() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func about() {
        NSWorkspace.shared.open(URL(string: "https://github.com/kromtom/wolverine-v3pro-macos-bridge")!)
    }
    @objc private func quit() { model.quit() }

    @objc private func showLog() {
        if logWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: LogView(model: model)))
            w.title = "WolverineBridge Log"
            w.setContentSize(NSSize(width: 640, height: 360))
            w.isReleasedWhenClosed = false
            w.center()
            logWindow = w
        }
        NSApp.activate() // LSUIElement app: bring the window to the front
        logWindow?.makeKeyAndOrderFront(nil)
    }
}

private extension NSMenuItem {
    /// A disabled (grey) item that shows text, like a SwiftUI Text in a menu.
    static func info(_ title: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    /// Sets the title only when it changed, so an open menu redraws only what changed.
    func setTitle(_ t: String) { if title != t { title = t } }

    func setState(_ on: Bool, enabled: Bool) {
        let st: NSControl.StateValue = on ? .on : .off
        if state != st { state = st }
        if isEnabled != enabled { isEnabled = enabled }
    }
}

/// Live log, newest first. A window instead of a submenu: a submenu closes on each menu rebuild.
struct LogView: View {
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
