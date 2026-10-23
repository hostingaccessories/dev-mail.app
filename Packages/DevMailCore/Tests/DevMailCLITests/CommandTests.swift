import ArgumentParser
import DevMailCore
import Foundation
import Synchronization
import Testing

@testable import DevMailCLI

/// Parses real command lines and runs them against a control server on a short temporary socket path, with a stub
/// in place of the app.
@Suite(.timeLimit(.minutes(1)))
struct CommandTests {
    // MARK: - Parsing

    @Test func buildsSettingsPatch() throws {
        let command = try parse(
            ConfigureCommand.self,
            ["configure", "--port", "2525", "--max-messages", "off", "--max-age-days", "7", "--dock-icon", "off"]
        )
        #expect(
            command.patch
                == ControlSettingsPatch(
                    port: 2525,
                    limitsMessageCount: false,
                    limitsMessageAge: true,
                    maxAgeInDays: 7,
                    hidesDockIcon: true
                )
        )

        let reset = try parse(ConfigureCommand.self, ["configure", "--reset-server", "--menu-bar", "yes"])
        #expect(reset.patch == ControlSettingsPatch(host: "127.0.0.1", port: 1025, showsMenuBarItem: true))
        #expect(try parse(ConfigureCommand.self, ["configure"]).patch.isEmpty)
    }

    @Test(arguments: [
        ["configure", "--reset-server", "--port", "2525"],
        ["configure", "--port", "0"],
        ["configure", "--max-messages", "0"],
        ["configure", "--menu-bar", "maybe"],
        ["mail", "delete"],
        ["mail", "delete", "--all", "abc"],
        ["mail", "show", "abc", "--raw", "--json"],
        ["mail", "list", "--limit", "0"],
    ])
    func rejectsInvalidArguments(arguments: [String]) {
        #expect(throws: (any Error).self) { try DevMailCommand.parseAsRoot(arguments) }
    }

    // MARK: - Running

    @Test func listsAndShowsMessages() async throws {
        let message = Fixtures.summary(subject: "Hello", receivedAt: Fixtures.now)
        let raw = Data("From: app@example.com\r\nSubject: Hello\r\n\r\nHi there\r\n".utf8)
        let handler: ControlServer.Handler = { request in
            switch request {
            case .listMessages(query: "hel", limit: 5, unreadOnly: true): .messages([message])
            case .showMessage(id: "abc"): .message(message, raw: raw)
            default: .failure(reason: "Unexpected request \(request)")
            }
        }
        try await withApp(handler) { app in
            let list = try await app.run(["mail", "list", "--search", "hel", "-n", "5", "--unread"])
            #expect(list.hasSuffix("  Hello\n"))

            let json = try await app.run(["mail", "list", "-s", "hel", "-n", "5", "--unread", "--json"])
            let decoded = try JSONDecoder.iso8601.decode([MessageSummary].self, from: Data(json.utf8))
            #expect(decoded.map(\.id) == [message.id])

            let source = try await app.run(["mail", "show", "abc", "--raw"])
            let shown = try await app.run(["mail", "show", "abc"])
            #expect(source == String(bytes: raw, encoding: .utf8))
            #expect(shown.contains("Subject: Hello\n"))
            #expect(shown.hasSuffix("\n\nHi there\n"))
            await #expect(throws: CLIError("The message has no HTML body.")) {
                try await app.run(["mail", "show", "abc", "--html"])
            }
        }
    }

    @Test func reportsFailuresFromTheApp() async throws {
        try await withApp(answering: .failure(reason: "No message with ID ffff.")) { app in
            await #expect(throws: CLIError("No message with ID ffff.")) {
                try await app.run(["mail", "delete", "ffff"])
            }
        }
    }

    @Test func confirmsBeforeDeletingEverything() async throws {
        try await withApp(answering: .deleted(count: 3)) { app in
            // Nobody to ask.
            await #expect(throws: CLIError("Pass --yes to delete every message without being asked.")) {
                try await app.run(["mail", "delete", "--all"])
            }
            let declined = try await app.run(["mail", "delete", "--all"], answer: false)
            let accepted = try await app.run(["mail", "delete", "--all"], answer: true)
            let unasked = try await app.run(["mail", "delete", "--all", "--yes"])
            #expect(declined.isEmpty)
            #expect(accepted == "Deleted 3 messages.\n")
            #expect(unasked == "Deleted 3 messages.\n")
            #expect(app.questions == Array(repeating: "Delete all messages? This can't be undone.", count: 2))
        }
    }

    @Test func confirmsBeforeRetentionDeletesMessages() async throws {
        let settings = ControlSettings(
            host: "127.0.0.1",
            port: 1025,
            limitsMessageCount: true,
            maxMessageCount: 1,
            limitsMessageAge: false,
            maxAgeInDays: 30,
            showsMenuBarItem: false,
            hidesDockIcon: false,
            opensAtLogin: false
        )
        let handler: ControlServer.Handler = { request in
            guard case .updateSettings(_, let confirmed) = request else { return .failure(reason: "Unexpected") }
            return confirmed ? .settings(settings) : .confirmationRequired(count: 2)
        }
        try await withApp(handler) { app in
            await #expect(throws: CLIError("This would delete 2 messages. Pass --yes to apply it anyway.")) {
                try await app.run(["configure", "--max-messages", "1"])
            }
            await #expect(throws: CLIError("Settings not changed.")) {
                try await app.run(["configure", "--max-messages", "1"], answer: false)
            }
            let confirmed = try await app.run(["configure", "--max-messages", "1"], answer: true)
            let unasked = try await app.run(["configure", "--max-messages", "1", "--yes"])
            #expect(confirmed.contains("most recent 1"))
            #expect(unasked.contains("most recent 1"))
        }
    }

    @Test func reportsServerThatCouldNotMove() async throws {
        let settings = ControlSettings(
            host: "127.0.0.1",
            port: 25,
            limitsMessageCount: true,
            maxMessageCount: 1000,
            limitsMessageAge: false,
            maxAgeInDays: 30,
            showsMenuBarItem: false,
            hidesDockIcon: false,
            opensAtLogin: false
        )
        let status = ControlServerStatus(
            state: .failed,
            host: "127.0.0.1",
            port: 25,
            failureReason: "Permission denied when listening on port 25.",
            messageCount: 0,
            unreadCount: 0,
            messagesDirectory: "/tmp"
        )
        let handler: ControlServer.Handler = { request in
            if case .serverStatus = request { return .status(status) }
            return .settings(settings)
        }
        try await withApp(handler) { app in
            let error = CLIError(
                "Settings saved, but the server couldn't start: Permission denied when listening on port 25."
            )
            await #expect(throws: error) {
                try await app.run(["configure", "--port", "25"])
            }
        }
    }

    @Test func serverStatusAndStopDontOpenTheApp() async throws {
        try await withApp(answering: .deleted(count: 0), running: false) { app in
            let text = try await app.run(["server", "status"])
            let json = try await app.run(["server", "status", "--json"])
            #expect(text == "Dev Mail isn't running.\n")
            #expect(json.contains("\"isAppRunning\" : false"))
            await #expect(throws: ControlClientError.notRunning) { try await app.run(["server", "stop"]) }
            #expect(app.launchCount == 0)
        }
    }

    @Test func opensTheAppWhenNeeded() async throws {
        try await withApp(answering: .messages([]), running: false) { app in
            let output = try await app.run(["mail", "list"])
            #expect(output == "No messages.\n")
            #expect(app.launchCount == 1)
        }
    }

    @Test func givesUpWhenTheAppDoesNotStart() async throws {
        try await withApp(answering: .messages([]), running: false, startsOnLaunch: false) { app in
            await #expect(throws: CLIError("Dev Mail didn't start in time.")) { try await app.run(["mail", "list"]) }
            #expect(app.launchCount == 1)
        }
    }

    // MARK: - Helpers

    private func parse<Command: ParsableCommand>(_ type: Command.Type, _ arguments: [String]) throws -> Command {
        let command = try DevMailCommand.parseAsRoot(arguments)
        return try #require(command as? Command)
    }
}
