import DevMailCore
import Foundation
import Testing

@testable import DevMailCLI

/// Sends through the real command to a real SMTP server, with a stub app reporting where it listens.
@Suite(.timeLimit(.minutes(1)))
struct SendCommandTests {
    @Test func composesFromOptionsAndStandardInput() async throws {
        try await withSMTPServer { smtp in
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "DevMailCLITests-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let attachment = directory.appending(path: "notes.txt")
            try Data("attached".utf8).write(to: attachment)

            try await withApp(answering: .status(smtp.status)) { app in
                let output = try await app.run(
                    [
                        "mail", "send", "--from", "App <app@example.test>", "--to",
                        "Jane <jane@example.test>, bob@example.test",
                        "--bcc", "audit@example.test", "-s", "Héllo", "--attach", attachment.path(), "-H",
                        "X-Campaign: launch",
                    ],
                    input: Data("Body from stdin\n".utf8)
                )

                let message = try #require(await smtp.messages.next())
                #expect(output == MessageIDMatcher.shortID(message.id) + "\n")
                #expect(message.envelopeSender == "app@example.test")
                #expect(message.recipients == ["jane@example.test", "bob@example.test", "audit@example.test"])

                let parsed = MIMEParser.parse(message.data)
                #expect(parsed.subject == "Héllo")
                #expect(parsed.from == [EmailAddress(name: "App", address: "app@example.test")])
                #expect(parsed.to.map(\.address) == ["jane@example.test", "bob@example.test"])
                #expect(parsed.textBody == "Body from stdin\n")
                #expect(parsed.headerValue(named: "X-Campaign") == "launch")
                #expect(parsed.attachments.map(\.filename) == ["notes.txt"])
                #expect(parsed.attachments.first?.mimeType == "text/plain")
            }
        }
    }

    @Test func sendsHTMLFromStandardInputWithTextOption() async throws {
        try await withSMTPServer { smtp in
            try await withApp(answering: .status(smtp.status)) { app in
                _ = try await app.run(
                    ["mail", "send", "--to", "a@example.test", "--body", "Plain", "--html", "-"],
                    input: Data("<p>Rich</p>".utf8)
                )
                let parsed = MIMEParser.parse(try #require(await smtp.messages.next()).data)
                #expect(parsed.textBody == "Plain")
                #expect(parsed.htmlBody == "<p>Rich</p>")
                #expect(parsed.from == [EmailAddress(address: "dev-mail@localhost")])
            }
        }
    }

    @Test func sendsRawMessageWithEnvelopeFromHeaders() async throws {
        let raw = Data("From: a@example.test\nTo: b@example.test\nBcc: c@example.test\nSubject: Raw\n\n.dot\n".utf8)
        try await withSMTPServer { smtp in
            try await withApp(answering: .status(smtp.status)) { app in
                _ = try await app.run(["mail", "send", "--eml", "-"], input: raw)
                let message = try #require(await smtp.messages.next())
                #expect(message.envelopeSender == "a@example.test")
                #expect(message.recipients == ["b@example.test", "c@example.test"])
                let expected =
                    "From: a@example.test\r\nTo: b@example.test\r\nBcc: c@example.test\r\n"
                    + "Subject: Raw\r\n\r\n.dot\r\n"
                #expect(message.data == Data(expected.utf8))

                // Options replace the envelope from the headers.
                _ = try await app.run(
                    ["mail", "send", "--eml", "-", "--to", "d@example.test", "--from", "e@example.test"],
                    input: raw
                )
                let override = try #require(await smtp.messages.next())
                #expect(override.envelopeSender == "e@example.test")
                #expect(override.recipients == ["d@example.test"])
            }
        }
    }

    @Test func usesGivenAddressWithoutTheApp() async throws {
        try await withSMTPServer { smtp in
            try await withApp(answering: .status(smtp.status), running: false, startsOnLaunch: false) { app in
                _ = try await app.run(
                    [
                        "mail", "send", "--to", "a@example.test", "--host", "127.0.0.1", "--port",
                        String(smtp.status.port),
                    ],
                    input: Data("Hi".utf8)
                )
                #expect(await smtp.messages.next() != nil)
                #expect(app.launchCount == 0)
            }
        }
    }

    @Test func reportsStoppedServer() async throws {
        let stopped = ControlServerStatus(
            state: .stopped,
            host: "127.0.0.1",
            port: 1025,
            messageCount: 0,
            unreadCount: 0,
            messagesDirectory: "/tmp"
        )
        try await withApp(answering: .status(stopped)) { app in
            await #expect(
                throws: CLIError("Dev Mail's SMTP server isn't running. Start it with `dev-mail server start`.")
            ) {
                try await app.run(["mail", "send", "--to", "a@example.test", "--body", "x"])
            }
        }
    }

    @Test func reportsBadInput() async throws {
        try await withApp(answering: .deleted(count: 0)) { app in
            await #expect(throws: CLIError("--to: \"<>\" is not an email address.")) {
                try await app.run(["mail", "send", "--to", "<>", "--body", "x", "--host", "::1", "--port", "1"])
            }
            await #expect(throws: CLIError("--header: \"oops\" should look like 'Name: value'.")) {
                try await app.run(["mail", "send", "--to", "a@b.c", "-H", "oops", "--host", "::1", "--port", "1"])
            }
            await #expect(
                throws: CLIError("The Content-Type header is set by Dev Mail; use the matching option instead.")
            ) {
                try await app.run(
                    [
                        "mail", "send", "--to", "a@b.c", "-H", "Content-Type: x", "--body", "x", "--host", "::1",
                        "--port", "1",
                    ]
                )
            }
            await #expect(throws: CLIError("Standard input is a terminal; pipe the content in or pass a file.")) {
                try await app.run(["mail", "send", "--eml", "-", "--host", "::1", "--port", "1"])
            }
        }
    }

    @Test(arguments: [
        ["mail", "send", "--body", "x"],
        ["mail", "send", "--eml", "-", "--subject", "x"],
        ["mail", "send", "--to", "a@b.c", "--port", "0"],
    ])
    func rejectsInvalidArguments(arguments: [String]) {
        #expect(throws: (any Error).self) { try DevMailCommand.parseAsRoot(arguments) }
    }

    @Test func connectsToWildcardServerOverLoopback() {
        #expect(MailCommand.Send.connectableHost("0.0.0.0") == "127.0.0.1")
        #expect(MailCommand.Send.connectableHost("::") == "::1")
        #expect(MailCommand.Send.connectableHost("192.168.1.2") == "192.168.1.2")
    }

    // MARK: - Helpers

    private final class SMTPFixture {
        let status: ControlServerStatus
        var messages: AsyncStream<ReceivedMessage>.Iterator

        init(port: UInt16, messages: AsyncStream<ReceivedMessage>) {
            status = ControlServerStatus(
                state: .listening,
                host: "127.0.0.1",
                port: port,
                messageCount: 0,
                unreadCount: 0,
                messagesDirectory: "/tmp"
            )
            self.messages = messages.makeAsyncIterator()
        }
    }

    private func withSMTPServer(_ body: (SMTPFixture) async throws -> Void) async throws {
        let (messages, continuation) = AsyncStream.makeStream(of: ReceivedMessage.self)
        let server = SMTPServer(configuration: SMTPServerConfiguration(port: 0)) { continuation.yield($0) }
        try await server.start()
        guard case .listening(_, let port) = await server.state else { throw CLIError("Not listening") }
        do {
            try await body(SMTPFixture(port: port, messages: messages))
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}
