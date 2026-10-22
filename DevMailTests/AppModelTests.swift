import DevMailCore
import Foundation
import Network
import Testing

@testable import DevMail

/// Runs the model against a real store in a temporary folder and a real server on an ephemeral loopback port.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppModelTests {
    @Test func startsListeningAndStops() async throws {
        try await withFixture { fixture in
            await fixture.model.start()
            let port = try fixture.listeningPort()
            #expect(fixture.model.serverState == .listening(host: "127.0.0.1", port: port))
            #expect(fixture.model.lastError == nil)

            await fixture.model.stopServer()
            #expect(fixture.model.serverState == .stopped)
            try SMTPTestClient.assertNothingListening(port: port)

            await fixture.model.startServer()
            #expect(fixture.model.serverState.isListening)
        }
    }

    @Test func showsReceivedMessages() async throws {
        try await withFixture { fixture in
            await fixture.model.start()

            try await SMTPTestClient.send(subject: "First", port: fixture.listeningPort())
            try await waitUntil { fixture.model.summaries.count == 1 }
            try await SMTPTestClient.send(subject: "Second", port: fixture.listeningPort())
            try await waitUntil { fixture.model.summaries.count == 2 }

            #expect(fixture.model.summaries.map(\.subject) == ["Second", "First"])
            #expect(fixture.model.unreadCount == 2)

            fixture.model.searchText = "  first "
            #expect(fixture.model.filteredSummaries.map(\.subject) == ["First"])

            let id = fixture.model.summaries[0].id
            let parsed = try await fixture.model.parsedMessage(for: id)
            #expect(parsed.subject == "Second")
            #expect(try await fixture.model.fileURL(for: id).pathExtension == "eml")
        }
    }

    @Test func loadsExistingMessagesAndAppliesActions() async throws {
        try await withFixture { fixture in
            let store = try await MessageStore(directory: fixture.directory)
            let old = try await store.add(Self.message(subject: "Old", receivedAt: Date(timeIntervalSince1970: 1)))
            let new = try await store.add(Self.message(subject: "New", receivedAt: Date(timeIntervalSince1970: 2)))

            await fixture.model.start()
            #expect(fixture.model.summaries.map(\.id) == [new.id, old.id])

            await fixture.model.markRead(new.id, isRead: true)
            try await waitUntil { fixture.model.unreadCount == 1 }
            #expect(fixture.model.summaries.first?.isRead == true)

            await fixture.model.delete(ids: [old.id])
            try await waitUntil { fixture.model.summaries.map(\.id) == [new.id] }

            await fixture.model.deleteAll()
            try await waitUntil { fixture.model.summaries.isEmpty }
            #expect(fixture.model.lastError == nil)
        }
    }

    @Test func importsDemoMessages() async throws {
        try await withFixture { fixture in
            await fixture.model.start()

            await fixture.model.importDemoMessages()
            try await waitUntil { fixture.model.summaries.count == 10 }
            #expect(fixture.model.unreadCount == 10)
            #expect(fixture.model.lastError == nil)
        }
    }

    @Test func appliesRetentionPolicy() async throws {
        try await withFixture { fixture in
            let store = try await MessageStore(directory: fixture.directory)
            try await store.add(Self.message(subject: "Old", receivedAt: Date(timeIntervalSince1970: 1)))
            let new = try await store.add(Self.message(subject: "New", receivedAt: Date(timeIntervalSince1970: 2)))

            await fixture.model.start()
            await fixture.model.updateRetentionPolicy(RetentionPolicy(maxMessageCount: 1))
            try await waitUntil { fixture.model.summaries.map(\.id) == [new.id] }
            #expect(fixture.model.retentionPolicy.maxMessageCount == 1)
        }
    }

    @Test func reportsPortInUse() async throws {
        try await withFixture { first in
            await first.model.start()
            let port = try first.listeningPort()

            try await withFixture(port: port) { second in
                await second.model.start()

                #expect(second.model.serverState == .failed(.addressInUse(port: port)))
                #expect(second.model.lastError?.suggestsSettings == true)
            }
        }
    }

    @Test func restartsWithNewConfiguration() async throws {
        try await withFixture { fixture in
            await fixture.model.start()
            let firstPort = try fixture.listeningPort()

            let configuration = SMTPServerConfiguration(port: 0, maxConnections: 4)
            await fixture.model.restartServer(with: configuration)
            let newPort = try fixture.listeningPort()
            #expect(fixture.model.serverConfiguration == configuration)
            try SMTPTestClient.assertNothingListening(port: firstPort)

            try await SMTPTestClient.send(subject: "After restart", port: newPort)
            try await waitUntil { fixture.model.summaries.count == 1 }

            await fixture.model.shutdown()
            #expect(fixture.model.serverState == .stopped)
        }
    }

    @Test func appliesServerAddressOnlyWhenChanged() async throws {
        try await withFixture { fixture in
            await fixture.model.start()
            let ephemeralPort = try fixture.listeningPort()

            // Moving from "any port" to a fixed one restarts; the ephemeral port was just freed, so it's available.
            #expect(await fixture.model.applyServerAddress(host: "127.0.0.1", port: ephemeralPort))
            #expect(fixture.model.serverConfiguration.port == ephemeralPort)
            #expect(fixture.model.serverState == .listening(host: "127.0.0.1", port: ephemeralPort))

            #expect(!(await fixture.model.applyServerAddress(host: "127.0.0.1", port: ephemeralPort)))

            #expect(await fixture.model.applyServerAddress(host: "127.0.0.1", port: 0))
            #expect(fixture.model.serverConfiguration.port == 0)
            #expect(try fixture.listeningPort() != 0)
            try SMTPTestClient.assertNothingListening(port: ephemeralPort)
        }
    }

    @Test func reportsFailedSaveButAcceptsMessage() async throws {
        try await withFixture { fixture in
            await fixture.model.start()

            // A read-only messages folder makes every save fail. `tearDown()` makes it writable again.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path())

            // `send` throws unless the server replies 250 to the message.
            try await SMTPTestClient.send(subject: "Unsaved", port: fixture.listeningPort())
            try await waitUntil { fixture.model.lastError != nil }
            #expect(fixture.model.lastError?.title == "Couldn't Save Message")
            #expect(fixture.model.summaries.isEmpty)
        }
    }

    @Test func doesNotStartServerWithoutStore() async throws {
        try await withFixture { fixture in
            // A file where the messages folder should be.
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try Data().write(to: fixture.directory)

            await fixture.model.start()

            #expect(fixture.model.serverState == .stopped)
            #expect(fixture.model.lastError != nil)
            await #expect(throws: AppModelError.self) { try await fixture.model.parsedMessage(for: UUID()) }
        }
    }

    // MARK: - Helpers

    /// Runs `body` with a fresh fixture and always tears it down, even when `body` throws.
    private func withFixture(port: UInt16 = 0, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = Fixture(port: port)
        do {
            try await body(fixture)
        } catch {
            await fixture.tearDown()
            throw error
        }
        await fixture.tearDown()
    }

    private static func message(subject: String, receivedAt: Date) -> ReceivedMessage {
        let raw = "From: sender@example.com\r\nTo: rcpt@example.com\r\nSubject: \(subject)\r\n\r\nBody\r\n"
        return ReceivedMessage(
            envelopeSender: "sender@example.com",
            recipients: ["rcpt@example.com"],
            data: Data(raw.utf8),
            receivedAt: receivedAt
        )
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestFailure("Timed out waiting for condition") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A model using a unique temporary folder and, by default, an ephemeral port.
@MainActor
private struct Fixture {
    let root: URL
    let model: AppModel

    var directory: URL { root.appending(path: "Messages", directoryHint: .isDirectory) }

    init(port: UInt16) {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DevMailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        model = AppModel(
            directory: root.appending(path: "Messages", directoryHint: .isDirectory),
            configuration: SMTPServerConfiguration(port: port)
        )
    }

    func listeningPort() throws -> UInt16 {
        guard case .listening(_, let port) = model.serverState else {
            throw TestFailure("Server is not listening: \(model.serverState)")
        }
        return port
    }

    /// Stops the server and deletes the temporary folder.
    func tearDown() async {
        await model.shutdown()
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path())
        try? FileManager.default.removeItem(at: root)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// A minimal SMTP client over a real TCP connection.
private actor SMTPTestClient {
    private let connection: NWConnection
    private var buffer = Data()

    private init(port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw TestFailure("Invalid port \(port)") }
        connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        connection.start(queue: DispatchQueue(label: "SMTPTestClient"))
    }

    deinit {
        connection.cancel()
    }

    /// Sends one message and throws unless every reply has the expected code.
    static func send(subject: String, port: UInt16) async throws {
        let client = try SMTPTestClient(port: port)
        let body = "From: sender@example.com\r\nTo: rcpt@example.com\r\nSubject: \(subject)\r\n\r\nHello\r\n.\r\n"
        let exchange: [(command: String?, expectedCode: String)] = [
            (nil, "220"),
            ("EHLO client.test\r\n", "250"),
            ("MAIL FROM:<sender@example.com>\r\n", "250"),
            ("RCPT TO:<rcpt@example.com>\r\n", "250"),
            ("DATA\r\n", "354"),
            (body, "250"),
            ("QUIT\r\n", "221"),
        ]
        for step in exchange {
            if let command = step.command {
                try await client.write(command)
            }
            let reply = try await client.readReply()
            guard reply.hasPrefix(step.expectedCode) else {
                throw TestFailure("Expected \(step.expectedCode), got \(reply)")
            }
        }
    }

    /// Throws if a blocking connect to the port succeeds, i.e. something is still listening.
    nonisolated static func assertNothingListening(port: UInt16) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            throw TestFailure("Port \(port) is still accepting connections")
        }
    }

    private func write(_ text: String) async throws {
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

    /// Reads one complete reply: up to the first line with a space after the code.
    private func readReply() async throws -> String {
        while true {
            if let end = completeReplyEnd() {
                let reply = buffer[..<end]
                buffer.removeSubrange(..<end)
                guard let text = String(bytes: reply, encoding: .utf8) else {
                    throw TestFailure("Server sent invalid UTF-8")
                }
                return text
            }
            buffer.append(try await receive())
        }
    }

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

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(throwing: TestFailure("Connection closed mid-reply"))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}
