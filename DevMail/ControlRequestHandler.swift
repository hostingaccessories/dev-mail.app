import DevMailCore
import Foundation

/// Answers requests from the `dev-mail` tool by acting on the model, as the corresponding UI would.
final class ControlRequestHandler {
    private let model: AppModel
    private let userDefaults: UserDefaults
    private let openAtLogin: OpenAtLoginSetting

    init(model: AppModel, userDefaults: UserDefaults = .standard, openAtLogin: OpenAtLoginSetting) {
        self.model = model
        self.userDefaults = userDefaults
        self.openAtLogin = openAtLogin
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            switch request {
            case .listMessages(let query, let limit, let unreadOnly):
                return listMessages(query: query, limit: limit, unreadOnly: unreadOnly)
            case .showMessage(let id):
                return try await showMessage(id: id)
            case .deleteMessages(let ids):
                return try await deleteMessages(ids: ids)
            case .deleteAllMessages:
                let ids = Set(model.summaries.map(\.id))
                try await model.deleteReportingErrors(ids: ids)
                return .deleted(count: ids.count)
            case .serverStatus:
                return .status(status)
            case .startServer:
                await model.startServer()
                return .status(status)
            case .stopServer:
                await model.stopServer()
                return .status(status)
            case .getSettings:
                return .settings(settings)
            case .updateSettings(let patch, let confirmDeletion):
                return await updateSettings(patch, confirmDeletion: confirmDeletion)
            }
        } catch {
            return .failure(reason: error.localizedDescription)
        }
    }

    // MARK: - Messages

    private func listMessages(query: String?, limit: Int?, unreadOnly: Bool) -> ControlResponse {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var summaries = model.summaries.filter { summary in
            (query.isEmpty || summary.matches(query)) && (!unreadOnly || !summary.isRead)
        }
        if let limit, limit >= 0 {
            summaries = Array(summaries.prefix(limit))
        }
        return .messages(summaries)
    }

    private func showMessage(id: String) async throws -> ControlResponse {
        let id = try MessageIDMatcher.match(id, in: model.summaries.map(\.id))
        guard let summary = model.summaries.first(where: { $0.id == id }) else {
            throw MessageIDMatcher.MatchError.notFound(id.uuidString)
        }
        return .message(summary, raw: try await model.rawData(for: id))
    }

    /// Resolves every ID before deleting any, so a typo doesn't leave a partial deletion.
    private func deleteMessages(ids: [String]) async throws -> ControlResponse {
        let known = model.summaries.map(\.id)
        var resolved = Set<UUID>()
        for id in ids {
            resolved.insert(try MessageIDMatcher.match(id, in: known))
        }
        try await model.deleteReportingErrors(ids: resolved)
        return .deleted(count: resolved.count)
    }

    // MARK: - Server

    private var status: ControlServerStatus {
        let configuration = model.serverConfiguration
        var status = ControlServerStatus(
            state: .stopped,
            host: configuration.host,
            port: configuration.port,
            messageCount: model.summaries.count,
            unreadCount: model.unreadCount,
            messagesDirectory: model.directory.path(percentEncoded: false)
        )
        switch model.serverState {
        case .listening(let host, let port):
            status.state = .listening
            status.host = host
            status.port = port
        case .stopped:
            break
        case .failed(let error):
            status.state = .failed
            status.failureReason = error.localizedDescription
        }
        return status
    }

    // MARK: - Settings

    private var settings: ControlSettings {
        let settings = AppSettings(userDefaults: userDefaults)
        openAtLogin.refresh()
        return ControlSettings(
            host: settings.host,
            port: settings.port,
            limitsMessageCount: settings.limitsMessageCount,
            maxMessageCount: settings.maxMessageCount,
            limitsMessageAge: settings.limitsMessageAge,
            maxAgeInDays: settings.maxAgeInDays,
            showsMenuBarItem: settings.showsMenuBarItem,
            hidesDockIcon: settings.hidesDockIcon,
            opensAtLogin: openAtLogin.isEnabled
        )
    }

    /// Validates the whole patch before saving any of it, then saves and applies it like the Settings window does.
    private func updateSettings(_ patch: ControlSettingsPatch, confirmDeletion: Bool) async -> ControlResponse {
        let current = AppSettings(userDefaults: userDefaults)
        let updated: AppSettings
        switch Self.applying(patch, to: current) {
        case .success(let settings): updated = settings
        case .failure(let error): return .failure(reason: error.reason)
        }

        if updated.retentionPolicy != current.retentionPolicy {
            let removedCount = updated.retentionPolicy.numberOfMessagesRemoved(
                receivedDates: model.summaries.map(\.receivedAt),
                now: .now
            )
            if removedCount > 0, !confirmDeletion {
                return .confirmationRequired(count: removedCount)
            }
        }

        if updated != current {
            updated.save(to: userDefaults)
            await model.apply(updated)
        }
        if let opensAtLogin = patch.opensAtLogin {
            openAtLogin.setEnabled(opensAtLogin)
        }
        model.noteExternalSettingsChange()

        if let errorMessage = openAtLogin.errorMessage {
            return .failure(reason: errorMessage)
        }
        return .settings(settings)
    }

    struct InvalidSetting: Error, Equatable {
        let reason: String
    }

    static func applying(_ patch: ControlSettingsPatch, to settings: AppSettings) -> Result<AppSettings, InvalidSetting>
    {
        var settings = settings
        if let host = patch.host {
            let host = host.trimmingCharacters(in: .whitespaces)
            guard AppSettings.isValidHost(host) else {
                return .failure(InvalidSetting(reason: "Enter an IP address, such as 127.0.0.1 or ::1, or localhost."))
            }
            settings.host = host
        }
        if let port = patch.port {
            guard port >= 1 else { return .failure(InvalidSetting(reason: "Enter a port from 1 to 65535.")) }
            settings.port = port
        }
        if let count = patch.maxMessageCount {
            guard count >= 1 else {
                return .failure(InvalidSetting(reason: "Enter a number of messages greater than 0."))
            }
            settings.maxMessageCount = count
        }
        if let days = patch.maxAgeInDays {
            guard days >= 1 else { return .failure(InvalidSetting(reason: "Enter a number of days greater than 0.")) }
            settings.maxAgeInDays = days
        }
        settings.limitsMessageCount = patch.limitsMessageCount ?? settings.limitsMessageCount
        settings.limitsMessageAge = patch.limitsMessageAge ?? settings.limitsMessageAge
        settings.showsMenuBarItem = patch.showsMenuBarItem ?? settings.showsMenuBarItem
        settings.hidesDockIcon = patch.hidesDockIcon ?? settings.hidesDockIcon
        return .success(settings)
    }
}
