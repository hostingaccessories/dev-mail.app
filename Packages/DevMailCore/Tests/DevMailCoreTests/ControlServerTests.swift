import Darwin
import Foundation
import Testing

@testable import DevMailCore

/// Runs a real control server on a socket in a short temporary folder: `sun_path` holds only 104 bytes, which the
/// usual per-user temporary directory plus a UUID would overflow.
@Suite(.timeLimit(.minutes(1)))
struct ControlServerTests {
    @Test func answersRequests() async throws {
        try await withSocketDirectory { directory in
            let socketURL = directory.appending(path: "control.sock")
            let server = ControlServer(socketURL: socketURL) { request in
                switch request {
                case .showMessage(let id): .failure(reason: "asked for \(id)")
                default: .deleted(count: 3)
                }
            }
            try await server.start()
            let client = ControlClient(socketURL: socketURL)

            #expect(client.isAppRunning)
            #expect(try client.send(.deleteAllMessages) == .deleted(count: 3))
            #expect(try client.send(.showMessage(id: "abc")) == .failure(reason: "asked for abc"))

            #expect(try StorageFixtures.posixPermissions(of: socketURL) & 0o777 == 0o600)
            #expect(try StorageFixtures.posixPermissions(of: directory) & 0o777 == 0o700)

            await server.stop()
            #expect(!FileManager.default.fileExists(atPath: socketURL.path()))
            #expect(throws: ControlClientError.notRunning) { try client.send(.serverStatus) }
            #expect(!client.isAppRunning)
        }
    }

    @Test func reportsNotRunningWithoutSocket() async throws {
        try await withSocketDirectory { directory in
            let client = ControlClient(socketURL: directory.appending(path: "missing.sock"))
            #expect(throws: ControlClientError.notRunning) { try client.send(.serverStatus) }
        }
    }

    @Test func replacesStaleSocket() async throws {
        try await withSocketDirectory { directory in
            let socketURL = directory.appending(path: "control.sock")
            // A socket file nothing listens on, as left behind by a crash.
            close(try Self.rawListener(at: socketURL))
            #expect(FileManager.default.fileExists(atPath: socketURL.path()))

            let server = ControlServer(socketURL: socketURL) { _ in .deleted(count: 1) }
            try await server.start()
            #expect(try ControlClient(socketURL: socketURL).send(.deleteAllMessages) == .deleted(count: 1))
            await server.stop()
        }
    }

    @Test func refusesSocketInUse() async throws {
        try await withSocketDirectory { directory in
            let socketURL = directory.appending(path: "control.sock")
            let first = ControlServer(socketURL: socketURL) { _ in .deleted(count: 1) }
            try await first.start()

            let second = ControlServer(socketURL: socketURL) { _ in .deleted(count: 2) }
            await #expect(throws: ControlServerError.alreadyRunning) { try await second.start() }
            #expect(try ControlClient(socketURL: socketURL).send(.deleteAllMessages) == .deleted(count: 1))
            await first.stop()
        }
    }

    @Test func leavesOtherFilesAlone() async throws {
        try await withSocketDirectory { directory in
            let socketURL = directory.appending(path: "control.sock")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: socketURL)

            let server = ControlServer(socketURL: socketURL) { _ in .deleted(count: 0) }
            await #expect(throws: ControlServerError.pathInUse(socketURL.path())) { try await server.start() }
            #expect(try Data(contentsOf: socketURL) == Data("keep".utf8))
        }
    }

    @Test func rejectsTooLongPath() async throws {
        let socketURL = URL(filePath: "/tmp/" + String(repeating: "a", count: 120))
        let server = ControlServer(socketURL: socketURL) { _ in .deleted(count: 0) }
        await #expect(throws: ControlServerError.pathTooLong(socketURL.path())) { try await server.start() }
    }

    @Test(arguments: [
        ("{\"version\":999,\"body\":{}}\n", "different versions"),
        ("not json\n", "not valid"),
        ("{\"version\":1,\"body\":{\"unknownCommand\":{}}}\n", "not valid"),
        (String(repeating: "x", count: 70_000), "too long"),
    ])
    func rejectsBadRequests(line: String, reason: String) async throws {
        try await withSocketDirectory { directory in
            let socketURL = directory.appending(path: "control.sock")
            let server = ControlServer(socketURL: socketURL) { _ in .deleted(count: 0) }
            try await server.start()

            let reply = try Self.exchange(line, at: socketURL)
            let envelope = try JSONDecoder().decode(ControlEnvelope<ControlResponse>.self, from: reply)
            #expect(envelope.version == ControlProtocol.version)
            guard case .failure(let message) = envelope.body else {
                Issue.record("Expected a failure, got \(envelope.body)")
                return
            }
            #expect(message.contains(reason))
            await server.stop()
        }
    }

    @Test func closesIdleConnections() async throws {
        try await withSocketDirectory { directory in
            let socketURL = directory.appending(path: "control.sock")
            let server = ControlServer(socketURL: socketURL, readTimeout: .milliseconds(100)) { _ in .deleted(count: 0)
            }
            try await server.start()

            // Sends nothing, so the server gives up and closes without a reply.
            #expect(try Self.exchange("", at: socketURL).isEmpty)
            await server.stop()
        }
    }

    @Test func clientReportsVersionMismatch() async throws {
        try await withSocketDirectory { directory in
            let socketURL = directory.appending(path: "control.sock")
            let listener = try Self.rawListener(at: socketURL)
            defer { close(listener) }

            let reply = Task.detached {
                let connection = accept(listener, nil, nil)
                defer { close(connection) }
                // Read the request first, as the app does, so the client's write never meets a closed socket.
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                let line = "{\"version\":999,\"body\":{\"deleted\":{\"count\":1}}}\n"
                _ = line.withCString { write(connection, $0, strlen($0)) }
            }
            #expect(throws: ControlClientError.versionMismatch(appVersion: 999)) {
                try ControlClient(socketURL: socketURL).send(.serverStatus)
            }
            await reply.value
        }
    }

    @Test func encodesEveryRequest() throws {
        let requests: [ControlRequest] = [
            .listMessages(query: "hi", limit: 5, unreadOnly: true),
            .listMessages(query: nil, limit: nil, unreadOnly: false),
            .showMessage(id: "abcd1234"),
            .deleteMessages(ids: ["a", "b"]),
            .deleteAllMessages,
            .serverStatus,
            .startServer,
            .stopServer,
            .getSettings,
            .updateSettings(ControlSettingsPatch(port: 2525, limitsMessageAge: false), confirmDeletion: true),
        ]
        for request in requests {
            let data = try ControlCoding.encode(ControlEnvelope(request))
            #expect(data.last == UInt8(ascii: "\n"))
            #expect(data.dropLast().contains(UInt8(ascii: "\n")) == false)
            #expect(try JSONDecoder().decode(ControlEnvelope<ControlRequest>.self, from: data).body == request)
        }
    }

    // MARK: - Helpers

    private func withSocketDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = URL(filePath: "/tmp/dmc-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// Binds and listens on a socket without accepting, returning its descriptor.
    private static func rawListener(at socketURL: URL) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let address = UnixSocketAddress(path: socketURL.path(percentEncoded: false)) else {
            throw TestFailure("Path too long")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard address.withSockaddr({ bind(descriptor, $0, $1) }) == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw TestFailure("Couldn't listen: \(String(cString: strerror(errno)))")
        }
        return descriptor
    }

    /// Sends `line` as is, then reads until the server closes the connection.
    private static func exchange(_ line: String, at socketURL: URL) throws -> Data {
        guard let address = UnixSocketAddress(path: socketURL.path(percentEncoded: false)),
            case .success(let descriptor) = address.connect()
        else { throw TestFailure("Couldn't connect") }
        defer { close(descriptor) }

        let bytes = Array(line.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            // The server may stop reading once the request is too long.
            guard written > 0 else { break }
            offset += written
        }
        // A request without a line feed ends when the client closes its side. An empty one is left open to time out.
        if !line.isEmpty, !line.hasSuffix("\n") {
            shutdown(descriptor, SHUT_WR)
        }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return reply }
            reply.append(contentsOf: buffer[..<count])
        }
    }
}

@Suite struct MessageIDMatcherTests {
    private let ids = [
        UUID(uuidString: "AAAA1111-0000-0000-0000-000000000001"),
        UUID(uuidString: "AAAA2222-0000-0000-0000-000000000002"),
        UUID(uuidString: "BBBB1111-0000-0000-0000-000000000003"),
    ].compactMap(\.self)

    @Test func matchesUniquePrefixAndFullID() throws {
        #expect(try MessageIDMatcher.match("aaaa1", in: ids) == ids[0])
        #expect(try MessageIDMatcher.match(" BBBB ", in: ids) == ids[2])
        #expect(try MessageIDMatcher.match(ids[1].uuidString.lowercased(), in: ids) == ids[1])
        #expect(MessageIDMatcher.shortID(ids[0]) == "aaaa1111")
    }

    @Test func rejectsAmbiguousUnknownAndInvalid() {
        #expect(throws: MessageIDMatcher.MatchError.ambiguous("aaaa", matches: 2)) {
            try MessageIDMatcher.match("aaaa", in: ids)
        }
        #expect(throws: MessageIDMatcher.MatchError.notFound("cccc")) { try MessageIDMatcher.match("cccc", in: ids) }
        #expect(throws: MessageIDMatcher.MatchError.invalid("")) { try MessageIDMatcher.match("", in: ids) }
        #expect(throws: MessageIDMatcher.MatchError.invalid("../x")) { try MessageIDMatcher.match("../x", in: ids) }
    }
}
