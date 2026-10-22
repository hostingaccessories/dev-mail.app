import AppKit

/// Starts the model at launch, keeps the app (and its SMTP server) running with no windows open, and stops the server
/// cleanly before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let updater: AppUpdater
    private lazy var dockBadge = DockBadgeController(model: model)

    private var isTerminating = false

    /// Hosted unit tests launch the app; they must not bind port 1025 or touch the real messages folder.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    override init() {
        let settings = AppSettings(userDefaults: .standard)
        model = AppModel(configuration: settings.serverConfiguration(), retentionPolicy: settings.retentionPolicy)
        updater = AppUpdater(
            startingUpdater: !Self.isRunningTests && AppUpdater.hasPublicEDKey(Bundle.main.infoDictionary)
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
