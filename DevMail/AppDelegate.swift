import AppKit

/// Starts the model at launch, keeps the app (and its SMTP server) running with no windows open, and stops the server
/// cleanly before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private lazy var dockBadge = DockBadgeController(model: model)

    /// Reopens the main window; set by SwiftUI because `openWindow` is only reachable from a view's environment.
    var openMainWindow: (() -> Void)?

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        dockBadge.start()
        // Attachments previewed before a crash would otherwise stay in the temporary folder.
        AttachmentFileStore.shared.removeAll()
        Task { await model.start() }
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
        if !flag { openMainWindow?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
