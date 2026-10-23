import Foundation
import Network
import Testing

@testable import DevMailCore

/// Integration tests against a real server on an ephemeral loopback port.
@Suite(.timeLimit(.minutes(1)))
struct SMTPServerTests {
    // MARK: - Helpers

    private static func makeConfiguration(
        maxConnections: Int = 8,
        idleTimeout: Duration = .seconds(30)
    ) -> SMTPServerConfiguration {
        SMTPServerConfiguration(port: 0, maxConnections: maxConnections, idleTimeout: idleTimeout)
    }

    private static func listeningPort(of server: SMTPServer) async throws -> UInt16 {
        guard case .listening(_, let port) = await server.state else {
            throw TestFailure("Server is not listening: \(await server.state)")
        }
        return port
    }

    // MARK: - Tests

    @Test func deliversExactBytesSentOverSocket() async throws {
        let (messages, messagesContinuation) = AsyncStream.makeStream(of: ReceivedMessage.self)
        let server = SMTPServer(configuration: Self.makeConfiguration()) { message in
            messagesContinuation.yield(message)
        }
        try await server.start()
        let client = try await TestSMTPClient(port: Self.listeningPort(of: server))

        #expect(try await client.readReply().hasPrefix("220 "))
        try await client.send("EHLO client.test\r\n")
        #expect(try await client.readReply().contains("250 AUTH PLAIN LOGIN\r\n"))

        let credentials = Data("\u{0}user\u{0}secret".utf8).base64EncodedString()
        try await client.send("AUTH PLAIN \(credentials)\r\n")
        #expect(try await client.readReply().hasPrefix("235 "))

        // Pipelined envelope, as clients that see PIPELINING send it.
        try await client.send(
            "MAIL FROM:<sender@example.com>\r\nRCPT TO:<one@example.com>\r\nRCPT TO:<two@example.com>\r\n"
        )
        for _ in 0..<3 {
            #expect(try await client.readReply().hasPrefix("250 "))
        }
        try await client.send("DATA\r\n")
        #expect(try await client.readReply().hasPrefix("354 "))

        let body = "From: sender@example.com\r\nSubject: Test\r\n\r\n.leading dot\r\nH\u{E9}llo\r\n"
        let stuffedBody = "From: sender@example.com\r\nSubject: Test\r\n\r\n..leading dot\r\nH\u{E9}llo\r\n"
        try await client.send(stuffedBody + ".\r\n")
        #expect(try await client.readReply().hasPrefix("250 "))

        try await client.send("QUIT\r\n")
        #expect(try await client.readReply().hasPrefix("221 "))
        #expect(try await client.readUntilClosed().isEmpty)

        var iterator = messages.makeAsyncIterator()
        let message = await iterator.next()
        #expect(message?.envelopeSender == "sender@example.com")
        #expect(message?.recipients == ["one@example.com", "two@example.com"])
        #expect(message?.data == Data(body.utf8))

        await server.stop()
        #expect(await server.state == .stopped)
    }

    @Test func servesConcurrentClients() async throws {
        let server = SMTPServer(configuration: Self.makeConfiguration()) { _ in }
        try await server.start()
        let port = try await Self.listeningPort(of: server)

        let first = try await TestSMTPClient(port: port)
        let second = try await TestSMTPClient(port: port)
        #expect(try await first.readReply().hasPrefix("220 "))
        #expect(try await second.readReply().hasPrefix("220 "))

        try await second.send("NOOP\r\n")
        #expect(try await second.readReply().hasPrefix("250 "))
        try await first.send("NOOP\r\n")
        #expect(try await first.readReply().hasPrefix("250 "))

        await server.stop()
    }

    @Test func reportsAddressInUse() async throws {
        let first = SMTPServer(configuration: Self.makeConfiguration()) { _ in }
        try await first.start()
        let port = try await Self.listeningPort(of: first)

        let second = SMTPServer(configuration: SMTPServerConfiguration(port: port)) { _ in }
        await #expect(throws: SMTPServerError.addressInUse(port: port)) {
            try await second.start()
        }
        #expect(await second.state == .failed(.addressInUse(port: port)))

        await second.stop()
        await first.stop()
    }

    @Test func rejectsClientsOverConnectionLimit() async throws {
        let server = SMTPServer(configuration: Self.makeConfiguration(maxConnections: 1)) { _ in }
        try await server.start()
        let port = try await Self.listeningPort(of: server)

        let first = try await TestSMTPClient(port: port)
        #expect(try await first.readReply().hasPrefix("220 "))

        let second = try await TestSMTPClient(port: port)
        #expect(try await second.readReply().hasPrefix("421 "))
        #expect(try await second.readUntilClosed().isEmpty)

        // The first client is unaffected.
        try await first.send("NOOP\r\n")
        #expect(try await first.readReply().hasPrefix("250 "))

        await server.stop()
    }

    @Test func closesIdleConnections() async throws {
        let server = SMTPServer(configuration: Self.makeConfiguration(idleTimeout: .milliseconds(200))) { _ in }
        try await server.start()
        let client = try await TestSMTPClient(port: Self.listeningPort(of: server))

        #expect(try await client.readReply().hasPrefix("220 "))
        #expect(try await client.readReply().hasPrefix("421 "))
        #expect(try await client.readUntilClosed().isEmpty)

        await server.stop()
    }

    @Test func stopClosesOpenConnections() async throws {
        let server = SMTPServer(configuration: Self.makeConfiguration()) { _ in }
        try await server.start()
        let client = try await TestSMTPClient(port: Self.listeningPort(of: server))
        #expect(try await client.readReply().hasPrefix("220 "))

        await server.stop()

        #expect(await server.state == .stopped)
        #expect(try await client.readUntilClosed().isEmpty)
    }

    @Test func publishesStateChanges() async throws {
        let server = SMTPServer(configuration: Self.makeConfiguration()) { _ in }
        var updates = await server.stateUpdates().makeAsyncIterator()
        #expect(await updates.next() == .stopped)

        try await server.start()
        let port = try await Self.listeningPort(of: server)
        #expect(await updates.next() == .listening(host: "127.0.0.1", port: port))

        await server.stop()
        #expect(await updates.next() == .stopped)
    }

    @Test func canRestartAfterStopping() async throws {
        let server = SMTPServer(configuration: Self.makeConfiguration()) { _ in }
        try await server.start()
        await server.stop()
        try await server.start()

        let client = try await TestSMTPClient(port: Self.listeningPort(of: server))
        #expect(try await client.readReply().hasPrefix("220 "))

        await server.stop()
    }
}

// MARK: - Test client

/// A minimal SMTP client over a real TCP connection.
private actor TestSMTPClient {
    private let connection: NWConnection
    private var buffer = Data()

    init(port: UInt16) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw TestFailure("Invalid port \(port)") }
        connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        connection.start(queue: DispatchQueue(label: "TestSMTPClient"))
    }

    deinit {
        connection.cancel()
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: Data(text.utf8),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Reads one complete reply, including every line of a multi-line reply.
    func readReply() async throws -> String {
        while true {
            if let end = completeReplyEnd() {
                let reply = buffer[..<end]
                buffer.removeSubrange(..<end)
                return try Self.text(reply)
            }
            guard let chunk = try await receive() else { throw TestFailure("Connection closed mid-reply") }
            buffer.append(chunk)
        }
    }

    /// Reads until the server closes the connection and returns anything received in the meantime.
    func readUntilClosed() async throws -> String {
        while let chunk = try await receive() {
            buffer.append(chunk)
        }
        defer { buffer = Data() }
        return try Self.text(buffer)
    }

    private static func text(_ data: Data) throws -> String {
        guard let text = String(bytes: data, encoding: .utf8) else { throw TestFailure("Server sent invalid UTF-8") }
        return text
    }

    /// The end index of the first complete reply in the buffer: the first line with a space after the code.
    private func completeReplyEnd() -> Int? {
        var lineStart = buffer.startIndex
        while let lineFeed = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[lineStart..<lineFeed]
            if line.count >= 4, line[line.startIndex + 3] == UInt8(ascii: " ") {
                return lineFeed + 1
            }
            lineStart = lineFeed + 1
        }
        return nil
    }

    private func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else if let error {
                    // A reset after the server closes counts as closed for these tests.
                    if case .posix(.ECONNRESET) = error {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}
