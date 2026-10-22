import AppKit

/// Starts the model at launch, keeps the app (and its SMTP server) running with no windows open, and stops the server
/// cleanly before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var isTerminating = false

    /// Hosted unit tests launch the app; they must not bind port 1025 or touch the real messages folder.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        Task { await model.start() }
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
