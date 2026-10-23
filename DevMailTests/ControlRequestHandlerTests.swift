import DevMailCore
import Foundation
import Testing

@testable import DevMail

/// Runs the handler against a model on a temporary folder and an ephemeral port, with throwaway settings and a fake
/// login item.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ControlRequestHandlerTests {
    @Test func listsShowsAndDeletesMessages() async throws {
        try await withFixture { fixture in
            let old = try await fixture.addMessage(subject: "Old", receivedAt: 1)
            let new = try await fixture.addMessage(subject: "New", receivedAt: 2)
            await fixture.start()

            #expect(
                await fixture.handle(.listMessages(query: nil, limit: nil, unreadOnly: false)) == .messages([new, old])
            )
            #expect(
                await fixture.handle(.listMessages(query: "old", limit: nil, unreadOnly: false)) == .messages([old])
            )
            #expect(await fixture.handle(.listMessages(query: nil, limit: 1, unreadOnly: false)) == .messages([new]))

            await fixture.model.markRead(new.id, isRead: true)
            try await waitUntil { fixture.model.unreadCount == 1 }
            guard
                case .messages(let unread) = await fixture.handle(
                    .listMessages(query: "", limit: nil, unreadOnly: true)
                )
            else {
                Issue.record("Expected messages")
                return
            }
            #expect(unread.map(\.id) == [old.id])

            let shortID = MessageIDMatcher.shortID(old.id)
            guard case .message(let summary, let raw) = await fixture.handle(.showMessage(id: shortID)) else {
                Issue.record("Expected a message")
                return
            }
            #expect(summary.id == old.id)
            #expect(String(bytes: raw, encoding: .utf8)?.contains("Subject: Old") == true)

            #expect(await fixture.handle(.showMessage(id: "zzz")) == .failure(reason: "\"zzz\" is not a message ID."))

            // An unknown ID fails the whole request, so nothing is deleted.
            let failed = await fixture.handle(.deleteMessages(ids: [shortID, "ffffffff"]))
            #expect(failed == .failure(reason: "No message with ID ffffffff."))
            #expect(fixture.model.summaries.count == 2)

            #expect(await fixture.handle(.deleteMessages(ids: [shortID])) == .deleted(count: 1))
            try await waitUntil { fixture.model.summaries.map(\.id) == [new.id] }

            #expect(await fixture.handle(.deleteAllMessages) == .deleted(count: 1))
            try await waitUntil { fixture.model.summaries.isEmpty }
            #expect(fixture.model.lastError == nil)
        }
    }

    @Test func reportsAndControlsServer() async throws {
        try await withFixture { fixture in
            await fixture.start()

            guard case .status(let listening) = await fixture.handle(.serverStatus) else {
                Issue.record("Expected a status")
                return
            }
            #expect(listening.state == .listening)
            #expect(listening.host == "127.0.0.1")
            #expect(listening.port != 0)
            #expect(listening.messagesDirectory == fixture.directory.path(percentEncoded: false))

            guard case .status(let stopped) = await fixture.handle(.stopServer) else {
                Issue.record("Expected a status")
                return
            }
            #expect(stopped.state == .stopped)
            #expect(fixture.model.serverState == .stopped)

            guard case .status(let restarted) = await fixture.handle(.startServer) else {
                Issue.record("Expected a status")
                return
            }
            #expect(restarted.state == .listening)
        }
    }

    @Test func updatesSettings() async throws {
        try await withFixture { fixture in
            await fixture.start()
            let revision = fixture.model.externalSettingsRevision

            let patch = ControlSettingsPatch(showsMenuBarItem: true, hidesDockIcon: true, opensAtLogin: true)
            guard case .settings(let settings) = await fixture.handle(.updateSettings(patch, confirmDeletion: false))
            else {
                Issue.record("Expected settings")
                return
            }
            #expect(settings.showsMenuBarItem && settings.hidesDockIcon && settings.opensAtLogin)
            #expect(fixture.model.showsMenuBarItem && fixture.model.hidesDockIcon)
            #expect(AppSettings(userDefaults: fixture.userDefaults).hidesDockIcon)
            #expect(fixture.loginItem.registerCount == 1)
            #expect(fixture.model.externalSettingsRevision == revision + 1)

            #expect(await fixture.handle(.getSettings) == .settings(settings))
        }
    }

    @Test func rejectsInvalidSettingsWithoutSavingAny() async throws {
        try await withFixture { fixture in
            await fixture.start()

            let patch = ControlSettingsPatch(host: "example.com", showsMenuBarItem: true)
            let response = await fixture.handle(.updateSettings(patch, confirmDeletion: false))
            #expect(response == .failure(reason: "Enter an IP address, such as 127.0.0.1 or ::1, or localhost."))
            #expect(AppSettings(userDefaults: fixture.userDefaults) == AppSettings())
            #expect(!fixture.model.showsMenuBarItem)

            #expect(
                ControlRequestHandler.applying(ControlSettingsPatch(port: 0), to: AppSettings())
                    == .failure(.init(reason: "Enter a port from 1 to 65535."))
            )
            #expect(
                ControlRequestHandler.applying(ControlSettingsPatch(maxAgeInDays: 0), to: AppSettings())
                    == .failure(.init(reason: "Enter a number of days greater than 0."))
            )
        }
    }

    @Test func asksBeforeRetentionDeletesMessages() async throws {
        try await withFixture { fixture in
            try await fixture.addMessage(subject: "Old", receivedAt: 1)
            let new = try await fixture.addMessage(subject: "New", receivedAt: 2)
            await fixture.start()

            let patch = ControlSettingsPatch(limitsMessageCount: true, maxMessageCount: 1)
            #expect(
                await fixture.handle(.updateSettings(patch, confirmDeletion: false)) == .confirmationRequired(count: 1)
            )
            #expect(AppSettings(userDefaults: fixture.userDefaults).maxMessageCount == AppSettings().maxMessageCount)
            #expect(fixture.model.summaries.count == 2)

            guard case .settings(let settings) = await fixture.handle(.updateSettings(patch, confirmDeletion: true))
            else {
                Issue.record("Expected settings")
                return
            }
            #expect(settings.maxMessageCount == 1)
            try await waitUntil { fixture.model.summaries.map(\.id) == [new.id] }
        }
    }

    @Test func movesServerToNewAddress() async throws {
        try await withFixture { fixture in
            await fixture.start()
            guard case .listening(_, let port) = fixture.model.serverState else {
                Issue.record("Server is not listening")
                return
            }
            await fixture.model.stopServer()

            // The ephemeral port was just freed, so it's available to move to.
            let patch = ControlSettingsPatch(host: " localhost ", port: port)
            guard case .settings(let settings) = await fixture.handle(.updateSettings(patch, confirmDeletion: false))
            else {
                Issue.record("Expected settings")
                return
            }
            #expect(settings.host == "localhost")
            #expect(fixture.model.serverState == .listening(host: "localhost", port: port))
        }
    }

    // MARK: - Helpers

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.tearDown()
            throw error
        }
        await fixture.tearDown()
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let suiteName = "DevMailTests-\(UUID().uuidString)"
    let userDefaults: UserDefaults
    let loginItem = FakeLoginItem()
    let model: AppModel
    let handler: ControlRequestHandler

    var directory: URL { root.appending(path: "Messages", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DevMailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        userDefaults = try #require(UserDefaults(suiteName: suiteName))
        model = AppModel(
            directory: root.appending(path: "Messages", directoryHint: .isDirectory),
            configuration: SMTPServerConfiguration(port: 0)
        )
        handler = ControlRequestHandler(
            model: model,
            userDefaults: userDefaults,
            openAtLogin: OpenAtLoginSetting(loginItem: loginItem)
        )
    }

    func start() async {
        await model.start()
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        await handler.handle(request)
    }

    /// Adds a message straight to the store; call before `start()` so the model loads it.
    @discardableResult
    func addMessage(subject: String, receivedAt seconds: TimeInterval) async throws -> MessageSummary {
        let store = try await MessageStore(directory: directory)
        let raw = "From: sender@example.com\r\nTo: rcpt@example.com\r\nSubject: \(subject)\r\n\r\nBody\r\n"
        return try await store.add(
            ReceivedMessage(
                envelopeSender: "sender@example.com",
                recipients: ["rcpt@example.com"],
                data: Data(raw.utf8),
                receivedAt: Date(timeIntervalSince1970: seconds)
            )
        )
    }

    func tearDown() async {
        await model.shutdown()
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
