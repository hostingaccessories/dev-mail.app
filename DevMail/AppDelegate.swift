import AppKit
import DevMailCore
import Observation
import os

nonisolated private let logger = Logger(subsystem: "com.hostingaccessories.DevMail", category: "AppDelegate")

/// Starts the model and the `dev-mail` control socket at launch, keeps the app (and its SMTP server) running with no
/// windows open, and stops both cleanly before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private lazy var dockBadge = DockBadgeController(model: model)
    private lazy var menuBar = MenuBarController(
        model: model,
        onOpenMail: { [weak self] in self?.showMainWindow() },
        onOpenSettings: { [weak self] in self?.showSettings() }
    )

    private lazy var controlServer: ControlServer = {
        let handler = ControlRequestHandler(model: model, openAtLogin: OpenAtLoginSetting())
        return ControlServer { request in await handler.handle(request) }
    }()

    /// Reopens the main window; set by SwiftUI because `openWindow` is only reachable from a view's environment.
    var openMainWindow: (() -> Void)?

    /// Opens the Settings window; set by SwiftUI for the same reason as `openMainWindow`.
    var openSettings: (() -> Void)?

    private var isTerminating = false

    /// Hosted unit tests launch the app; they must not bind port 1025 or touch the real messages folder.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    override init() {
        let settings = AppSettings(userDefaults: .standard)
        model = AppModel(
            configuration: settings.serverConfiguration(),
            retentionPolicy: settings.retentionPolicy,
            showsMenuBarItem: settings.showsMenuBarItem,
            hidesDockIcon: settings.hidesDockIcon
        )
        super.init()
    }

    /// Sets the activation policy before the app finishes launching, so a hidden Dock icon never appears.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        updateActivationPolicy(activates: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        dockBadge.start()
        menuBar.start()
        // Attachments previewed before a crash would otherwise stay in the temporary folder.
        AttachmentFileStore.shared.removeAll()
        Task {
            await model.start()
            await startControlServer()
        }
    }

    /// Starts listening for `dev-mail` commands once the messages are loaded. A failure only disables the tool, so it is
    /// logged rather than shown.
    private func startControlServer() async {
        do {
            try await controlServer.start()
        } catch {
            logger.error("Couldn't start the control socket: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        AttachmentFileStore.shared.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// SwiftUI doesn't reopen a single `Window` scene on a Dock click, so do it here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // MARK: - Windows

    /// Brings the main window to the front, activating the app first: without a Dock icon it isn't active on its own.
    func showMainWindow() {
        NSApp.activate()
        if let openMainWindow {
            openMainWindow()
        } else {
            // No view has registered `openWindow` yet (the window hasn't appeared since launch), so use the Window
            // menu's item for it instead.
            NSApp.mainMenu?.performItem(keyEquivalent: "0")
        }
    }

    func showSettings() {
        NSApp.activate()
        if let openSettings {
            openSettings()
        } else {
            NSApp.mainMenu?.performItem(keyEquivalent: ",")
        }
    }

    // MARK: - Dock icon

    /// Applies the model's activation policy, then again whenever the menu bar settings change.
    private func updateActivationPolicy(activates: Bool) {
        // `onChange` fires once, before the change is applied, so re-read and re-register on the next main-actor turn.
        let policy = withObservationTracking {
            model.activationPolicy
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateActivationPolicy(activates: true) }
        }
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Changing the policy deactivates the app, which would hide the main menu and send the Settings window behind
        // other apps' windows.
        if activates { NSApp.activate() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            if !Self.isRunningTests {
                await controlServer.stop()
            }
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension NSMenu {
    /// Performs the first enabled item, searching submenus, whose Command-key equivalent is `keyEquivalent`.
    @discardableResult
    func performItem(keyEquivalent: String) -> Bool {
        for (index, item) in items.enumerated() {
            if item.keyEquivalent == keyEquivalent, item.keyEquivalentModifierMask == .command, item.isEnabled {
                performActionForItem(at: index)
                return true
            }
            if let submenu = item.submenu, submenu.performItem(keyEquivalent: keyEquivalent) {
                return true
            }
        }
        return false
    }
}
