import Foundation
import Observation
import ServiceManagement
import os

nonisolated private let logger = Logger(subsystem: "com.hostingaccessories.DevMail", category: "LoginItem")

/// Registers an app to open at login. `SMAppService` conforms; tests use a fake so they never change the real login
/// items.
@MainActor
protocol LoginItem {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItem {}

/// The "Open at login" setting. The system owns the state rather than `UserDefaults`, because the user can also change
/// it in System Settings › General › Login Items; call `refresh()` to pick up those changes.
@Observable @MainActor
final class OpenAtLoginSetting {
    /// Whether Dev Mail is registered to open at login, including while it waits for the user's approval.
    private(set) var isEnabled = false

    /// Registered, but the user must allow it in System Settings before it takes effect.
    private(set) var requiresApproval = false

    /// Why the last change failed, shown until the next change or refresh.
    private(set) var errorMessage: String?

    private let loginItem: LoginItem

    init(loginItem: LoginItem = SMAppService.mainApp) {
        self.loginItem = loginItem
        refresh()
    }

    func refresh() {
        let status = loginItem.status
        isEnabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    /// Registers or unregisters the app. On failure the state reverts to what the system reports.
    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try loginItem.register()
            } else if loginItem.status != .notRegistered {
                try loginItem.unregister()
            }
        } catch {
            logger.error("Couldn't change the login item: \(error.localizedDescription, privacy: .public)")
            errorMessage =
                enabled
                ? "Dev Mail couldn't be added to your login items."
                : "Dev Mail couldn't be removed from your login items."
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
