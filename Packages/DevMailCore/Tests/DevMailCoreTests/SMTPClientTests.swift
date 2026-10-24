import Foundation
import Testing

@testable import DevMailCore

/// Sends to a real server on an ephemeral loopback port. The client blocks, so it runs on its own thread while the
/// server answers.
@Suite(.timeLimit(.minutes(1)))
struct SMTPClientTests {
    @Test func deliversComposedMessage() async throws {
        try await withServer { server, messages in
            let outgoing = OutgoingMessage(
                from: EmailAddress(address: "app@example.test"),
                to: [EmailAddress(address: "jane@example.test")],
                bcc: [EmailAddress(address: "audit@example.test")],
                subject: "Hello",
                textBody: ".starts with a dot\n..two dots\n"
            )
            let data = try MessageComposer.compose(outgoing)
            let delivery = try await send(
                data,
                from: "app@example.test",
                to: outgoing.envelopeRecipients,
                port: server.port
            )

            let received = try #require(await messages.next())
            #expect(received.envelopeSender == "app@example.test")
            #expect(received.recipients == ["jane@example.test", "audit@example.test"])
            #expect(received.data == data)
            #expect(delivery.queuedID == received.id)
            #expect(MIMEParser.parse(received.data).textBody == ".starts with a dot\n..two dots\n")
        }
    }

    @Test func normalizesLineEndings() async throws {
        try await withServer { server, messages in
            let raw = Data("Subject: LF only\n\n.dot\nlast line without break".utf8)
            _ = try await send(raw, from: nil, to: ["a@example.test"], port: server.port)

            let received = try #require(await messages.next())
            #expect(received.envelopeSender == nil)
            #expect(received.data == Data("Subject: LF only\r\n\r\n.dot\r\nlast line without break\r\n".utf8))
        }
    }

    @Test func reportsRejection() async throws {
        let configuration = SMTPServerConfiguration(port: 0, maxMessageSize: 10)
        try await withServer(configuration) { server, _ in
            let error = await #expect(throws: SMTPClientError.self) {
                try await send(
                    Data(String(repeating: "x", count: 100).utf8),
                    from: nil,
                    to: ["a@b.c"],
                    port: server.port
                )
            }
            guard case .rejected(let command, let reply) = error else {
                Issue.record("Expected a rejection, got \(String(describing: error))")
                return
            }
            #expect(command == "the message")
            #expect(reply.hasPrefix("552 "))
        }
    }

    @Test func refusesBadInputBeforeConnecting() {
        let client = SMTPClient(host: "127.0.0.1", port: 1)
        #expect(throws: SMTPClientError.noRecipients) { try client.send(Data(), from: nil, to: []) }
        #expect(throws: SMTPClientError.invalidAddress("a>\r\nQUIT")) {
            try client.send(Data(), from: nil, to: ["a>\r\nQUIT"])
        }
        #expect(throws: SMTPClientError.invalidAddress("b c")) { try client.send(Data(), from: "b c", to: ["a@b.c"]) }
        #expect(throws: SMTPClientError.invalidHost("example.com")) {
            try SMTPClient(host: "example.com", port: 25).send(Data(), from: nil, to: ["a@b.c"])
        }
    }

    @Test func reportsNothingListening() async throws {
        // Start and stop a server to find a port that's free.
        let server = SMTPServer(configuration: SMTPServerConfiguration(port: 0)) { _ in }
        try await server.start()
        guard case .listening(_, let port) = await server.state else { throw TestFailure("Not listening") }
        await server.stop()

        let error = await #expect(throws: SMTPClientError.self) {
            try await send(Data("x".utf8), from: nil, to: ["a@b.c"], port: port)
        }
        #expect(error == .connectionFailed(host: "127.0.0.1", port: port, reason: "Connection refused"))
    }

    @Test func preparesTransmissionData() {
        func transmitted(_ text: String) -> String {
            String(bytes: SMTPClient.transmissionData(Data(text.utf8)), encoding: .utf8) ?? ""
        }
        #expect(transmitted("a\r\nb\r\n") == "a\r\nb\r\n.\r\n")
        #expect(transmitted("a\nb") == "a\r\nb\r\n.\r\n")
        #expect(transmitted("a\rb\r") == "a\r\nb\r\n.\r\n")
        #expect(transmitted(".a\n.\nb.c") == "..a\r\n..\r\nb.c\r\n.\r\n")
        #expect(transmitted("") == ".\r\n")
    }

    @Test func readsQueuedID() {
        let id = UUID()
        #expect(SMTPClient.Delivery(reply: "OK: queued as \(id.uuidString)").queuedID == id)
        #expect(SMTPClient.Delivery(reply: "OK").queuedID == nil)
    }

    // MARK: - Helpers

    private struct RunningServer {
        let port: UInt16
    }

    private func withServer(
        _ configuration: SMTPServerConfiguration = SMTPServerConfiguration(port: 0),
        _ body: (RunningServer, inout AsyncStream<ReceivedMessage>.Iterator) async throws -> Void
    ) async throws {
        let (messages, continuation) = AsyncStream.makeStream(of: ReceivedMessage.self)
        let server = SMTPServer(configuration: configuration) { continuation.yield($0) }
        try await server.start()
        guard case .listening(_, let port) = await server.state else { throw TestFailure("Not listening") }

        var iterator = messages.makeAsyncIterator()
        do {
            try await body(RunningServer(port: port), &iterator)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func send(_ data: Data, from sender: String?, to recipients: [String], port: UInt16)
        async throws(SMTPClientError)
        -> SMTPClient.Delivery
    {
        let result = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let client = SMTPClient(host: "127.0.0.1", port: port, timeout: .seconds(5))
                continuation.resume(
                    returning: Result { () throws(SMTPClientError) in
                        try client.send(data, from: sender, to: recipients)
                    }
                )
            }
        }
        return try result.get()
    }
}
