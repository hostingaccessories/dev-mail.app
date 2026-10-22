import Darwin
import Foundation
import Testing

@testable import DevMailCore

/// How the server binds its port: what it must share the port with, and what it must refuse to share it with.
@Suite(.timeLimit(.minutes(1)))
struct SMTPServerBindingTests {
    // MARK: - Tests

    /// Reproduces issue #26: another process (`identityservicesd` in the wild) holds a connection whose local port
    /// is the one we want, on an address we don't listen on.
    @Test func startsWhilePortHasEstablishedConnectionOnAnotherAddress() async throws {
        let port = try TestSocket.unusedPort()
        let peer = try TestSocket.listening(family: AF_INET6, host: "::1", port: 0)
        let client = try TestSocket.connected(from: "::1", localPort: port, to: peer.localPort())
        let accepted = try peer.accept()
        defer {
            accepted.close()
            client.close()
            peer.close()
        }

        let server = SMTPServer(configuration: SMTPServerConfiguration(port: port)) { _ in }
        try await server.start()
        #expect(await server.state == .listening(host: "127.0.0.1", port: port))

        let smtpClient = try TestSocket.connected(to: "127.0.0.1", port: port)
        defer { smtpClient.close() }
        #expect(try await smtpClient.readLine().hasPrefix("220 "))

        await server.stop()
    }

    @Test(arguments: [false, true])
    func reportsAddressInUseWhenAnotherSocketListensOnLoopback(otherReusesAddress: Bool) async throws {
        let other = try TestSocket.listening(
            family: AF_INET,
            host: "127.0.0.1",
            port: 0,
            reuseAddress: otherReusesAddress
        )
        defer { other.close() }
        let port = try other.localPort()

        try await expectAddressInUse(port: port)
    }

    @Test(arguments: [false, true])
    func reportsAddressInUseWhenAnotherSocketListensOnWildcard(otherReusesAddress: Bool) async throws {
        let other = try TestSocket.listening(
            family: AF_INET,
            host: "0.0.0.0",
            port: 0,
            reuseAddress: otherReusesAddress
        )
        defer { other.close() }
        let port = try other.localPort()

        try await expectAddressInUse(port: port)
    }

    @Test func reportsAddressInUseWhenAnotherSocketListensOnDualStackWildcard() async throws {
        let other = try TestSocket.listening(family: AF_INET6, host: "::", port: 0)
        defer { other.close() }
        let port = try other.localPort()

        try await expectAddressInUse(port: port)
    }

    /// The server closes first after `QUIT`, leaving its side of the connection in TIME_WAIT on the listening port.
    @Test func restartsImmediatelyOnSamePortAfterClientDisconnects() async throws {
        let first = SMTPServer(configuration: SMTPServerConfiguration(port: 0)) { _ in }
        try await first.start()
        guard case .listening(_, let port) = await first.state else {
            Issue.record("Server is not listening")
            return
        }

        let client = try TestSocket.connected(to: "127.0.0.1", port: port)
        #expect(try await client.readLine().hasPrefix("220 "))
        try client.write("QUIT\r\n")
        #expect(try await client.readLine().hasPrefix("221 "))
        #expect(try await client.readLine().isEmpty)
        client.close()
        await first.stop()

        let second = SMTPServer(configuration: SMTPServerConfiguration(port: port)) { _ in }
        try await second.start()
        let secondClient = try TestSocket.connected(to: "127.0.0.1", port: port)
        defer { secondClient.close() }
        #expect(try await secondClient.readLine().hasPrefix("220 "))

        await second.stop()
    }

    /// Once `stop()` returns, the port must be closed, not just no longer served.
    @Test func refusesConnectionsAsSoonAsStopReturns() async throws {
        for withClient in [false, true] {
            for _ in 0..<500 {
                let server = SMTPServer(configuration: SMTPServerConfiguration(port: 0)) { _ in }
                try await server.start()
                guard case .listening(_, let port) = await server.state else {
                    Issue.record("Server is not listening")
                    return
                }
                let client = withClient ? try TestSocket.connected(to: "127.0.0.1", port: port) : nil

                await server.stop()

                #expect(TestSocket.connectError(to: "127.0.0.1", port: port) == ECONNREFUSED)
                client?.close()
            }
        }
    }

    @Test(arguments: ["localhost", "::1"])
    func listensOnLoopbackHosts(host: String) async throws {
        let server = SMTPServer(configuration: SMTPServerConfiguration(host: host, port: 0)) { _ in }
        try await server.start()
        guard case .listening(let listeningHost, let port) = await server.state else {
            Issue.record("Server is not listening")
            return
        }
        #expect(listeningHost == host)

        let client = try TestSocket.connected(to: host == "localhost" ? "127.0.0.1" : host, port: port)
        defer { client.close() }
        #expect(try await client.readLine().hasPrefix("220 "))

        await server.stop()
    }

    @Test func rejectsHostNamesOtherThanLocalhost() async throws {
        let server = SMTPServer(configuration: SMTPServerConfiguration(host: "mail.example.com", port: 0)) { _ in }
        await #expect {
            try await server.start()
        } throws: { error in
            guard case .listenerFailed(let reason) = error as? SMTPServerError else { return false }
            return reason.contains("mail.example.com")
        }
    }

    @Test func startingAndStoppingDoesNotLeakFileDescriptors() async throws {
        // Other suites open files and sockets in parallel, so allow some noise; a leak would add one or more per cycle.
        let cycles = 40
        let before = TestSocket.openFileDescriptorCount()
        for _ in 0..<cycles {
            let server = SMTPServer(configuration: SMTPServerConfiguration(port: 0, maxConnections: 1)) { _ in }
            try await server.start()
            guard case .listening(_, let port) = await server.state else {
                Issue.record("Server is not listening")
                return
            }
            let client = try TestSocket.connected(to: "127.0.0.1", port: port)
            #expect(try await client.readLine().hasPrefix("220 "))
            let rejected = try TestSocket.connected(to: "127.0.0.1", port: port)
            #expect(try await rejected.readLine().hasPrefix("421 "))
            rejected.close()
            await server.stop()
            #expect(try await client.readLine().isEmpty)
            client.close()
        }
        let after = TestSocket.openFileDescriptorCount()
        #expect(after - before < cycles / 2, "Open file descriptors grew from \(before) to \(after)")
    }

    // MARK: - Helpers

    private func expectAddressInUse(port: UInt16) async throws {
        let server = SMTPServer(configuration: SMTPServerConfiguration(port: port)) { _ in }
        await #expect(throws: SMTPServerError.addressInUse(port: port)) {
            try await server.start()
        }
        #expect(await server.state == .failed(.addressInUse(port: port)))
        await server.stop()
    }
}

// MARK: - Test sockets

private struct SocketFailure: Error, CustomStringConvertible {
    let code: Int32
    let description: String

    init(_ operation: String, errno code: Int32 = errno) {
        self.code = code
        description = "\(operation): \(String(cString: strerror(code)))"
    }
}

/// A blocking BSD socket, so tests can create exactly the socket states the server has to cope with.
private struct TestSocket: Sendable {
    let descriptor: Int32

    /// A port that is free on 127.0.0.1 and ::1 right now.
    static func unusedPort() throws -> UInt16 {
        for _ in 0..<20 {
            let probe = try listening(family: AF_INET, host: "127.0.0.1", port: 0)
            let port = try probe.localPort()
            probe.close()
            if let other = try? listening(family: AF_INET6, host: "::1", port: port) {
                other.close()
                return port
            }
        }
        throw SocketFailure("unusedPort", errno: EADDRINUSE)
    }

    static func listening(
        family: Int32,
        host: String,
        port: UInt16,
        reuseAddress: Bool = false
    ) throws -> TestSocket {
        let socket = try TestSocket(family: family)
        do {
            if reuseAddress {
                try socket.setOption(SO_REUSEADDR)
            }
            try socket.bind(host: host, port: port)
            guard Darwin.listen(socket.descriptor, 8) == 0 else { throw SocketFailure("listen") }
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    /// Connects from a specific local address and port.
    static func connected(from host: String, localPort: UInt16, to port: UInt16) throws -> TestSocket {
        let socket = try TestSocket(family: host.contains(":") ? AF_INET6 : AF_INET)
        do {
            try socket.bind(host: host, port: localPort)
            try socket.connect(host: host, port: port)
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    static func connected(to host: String, port: UInt16) throws -> TestSocket {
        let socket = try TestSocket(family: host.contains(":") ? AF_INET6 : AF_INET)
        do {
            try socket.connect(host: host, port: port)
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(socket.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    /// The `errno` a connection attempt fails with, or `nil` if it succeeds.
    static func connectError(to host: String, port: UInt16) -> Int32? {
        do {
            let socket = try connected(to: host, port: port)
            socket.close()
            return nil
        } catch let error as SocketFailure {
            return error.code
        } catch {
            return -1
        }
    }

    static func openFileDescriptorCount() -> Int {
        (0..<getdtablesize()).count { fcntl($0, F_GETFD) != -1 }
    }

    private init(family: Int32) throws {
        descriptor = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw SocketFailure("socket") }
        try setOption(SO_NOSIGPIPE)
    }

    func close() {
        Darwin.close(descriptor)
    }

    func accept() throws -> TestSocket {
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { throw SocketFailure("accept") }
        return TestSocket(descriptor: client)
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func localPort() throws -> UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw SocketFailure("getsockname") }
        // sin_port and sin6_port sit at the same offset.
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
    }

    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        guard Darwin.write(descriptor, bytes, bytes.count) == bytes.count else { throw SocketFailure("write") }
    }

    /// Reads one line, or returns "" once the peer has closed the connection.
    ///
    /// Blocks a dispatch thread rather than the cooperative pool, which the server needs to make progress.
    func readLine() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try readLineBlocking() })
            }
        }
    }

    private static func text(_ bytes: [UInt8]) throws -> String {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw SocketFailure("read", errno: EILSEQ) }
        return text
    }

    private func readLineBlocking() throws -> String {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 || (count < 0 && errno == ECONNRESET) {
                return try Self.text(line)
            }
            guard count == 1 else { throw SocketFailure("read") }
            line.append(byte)
            if byte == UInt8(ascii: "\n") {
                return try Self.text(line)
            }
        }
    }

    private func setOption(_ option: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, option, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketFailure("setsockopt")
        }
    }

    private func bind(host: String, port: UInt16) throws {
        let result = try Self.withAddress(host: host, port: port) { Darwin.bind(descriptor, $0, $1) }
        guard result == 0 else { throw SocketFailure("bind \(host):\(port)") }
    }

    private func connect(host: String, port: UInt16) throws {
        let result = try Self.withAddress(host: host, port: port) { Darwin.connect(descriptor, $0, $1) }
        guard result == 0 else { throw SocketFailure("connect \(host):\(port)") }
    }

    private static func withAddress(
        host: String,
        port: UInt16,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
    ) throws -> Int32 {
        if host.contains(":") {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else { throw SocketFailure("inet_pton") }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw SocketFailure("inet_pton") }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}
