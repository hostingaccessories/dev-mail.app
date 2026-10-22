import Darwin
import Dispatch

/// A non-blocking TCP listening socket that reports accepted client sockets as events.
///
/// The socket is closed exactly once, by the accept source's cancel handler, which also finishes the event stream.
/// Accepted descriptors are owned by whoever receives the `.accepted` event; one that can't be delivered because the
/// stream has ended is closed here.
final class ListeningSocket: Sendable {
    enum Event: Sendable {
        /// A connected, non-blocking client socket.
        case accepted(Int32)

        /// `accept` failed with something other than a transient error.
        case failed(SMTPServerError)
    }

    /// How long to wait for a probe connection before assuming something is listening.
    private static let probeTimeoutMilliseconds: Int32 = 1000

    /// The port the socket is bound to, which is the system-assigned one when port `0` was requested.
    let port: UInt16

    private let source: any DispatchSourceRead

    /// Binds to `host` and `port` and starts accepting connections on `queue`.
    ///
    /// - Throws: `SMTPServerError` if the host is not an IP literal or `localhost`, or the socket can't be bound.
    init(host: String, port requestedPort: UInt16, queue: DispatchQueue, events: AsyncStream<Event>.Continuation)
        throws(SMTPServerError)
    {
        guard let address = SocketAddress(host: host, port: requestedPort) else {
            throw .listenerFailed(
                reason: "\"\(host)\" is not an IP address. Use an IPv4 or IPv6 address, or localhost."
            )
        }

        let descriptor = try Self.makeSocket(family: address.family, port: requestedPort)
        do throws(SMTPServerError) {
            try Self.bind(descriptor, to: address, host: host, port: requestedPort)
            guard listen(descriptor, SOMAXCONN) == 0 else {
                throw SMTPServerError(errno: errno, operation: "listen", port: requestedPort)
            }
            guard let boundPort = SocketAddress.localPort(of: descriptor) else {
                throw SMTPServerError(errno: errno, operation: "getsockname", port: requestedPort)
            }
            port = boundPort
        } catch {
            close(descriptor)
            throw error
        }

        let reportedPort = port
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            Self.acceptPending(on: descriptor, port: reportedPort, events: events)
        }
        source.setCancelHandler {
            close(descriptor)
            events.finish()
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    /// Stops accepting connections and closes the socket. Already accepted connections are unaffected.
    func cancel() {
        source.cancel()
    }

    // MARK: - Setup

    private static func makeSocket(family: Int32, port: UInt16) throws(SMTPServerError) -> Int32 {
        let descriptor = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw SMTPServerError(errno: errno, operation: "socket", port: port)
        }
        guard configureNonBlocking(descriptor) else {
            let code = errno
            close(descriptor)
            throw SMTPServerError(errno: code, operation: "fcntl", port: port)
        }
        return descriptor
    }

    /// Binds the socket, allowing a quick restart without ever sharing the port with another listener.
    ///
    /// On macOS, `SO_REUSEADDR` does two things. It lets us bind while earlier connections on the port sit in
    /// TIME_WAIT, which we need so the server can restart immediately after `stop()`. But it also lets us bind a
    /// specific address next to another socket's wildcard listener (127.0.0.1:1025 next to 0.0.0.0:1025 or a
    /// dual-stack [::]:1025), and the kernel would then route loopback traffic to us instead of to, say, a Mailpit
    /// container. Binding the same address another socket listens on fails either way.
    ///
    /// So bind without `SO_REUSEADDR` first; that fails if anything at all uses the port on an overlapping address.
    /// Only then probe for a listener by connecting to the address (loopback for a wildcard host), which reaches a
    /// listener on that address or on the wildcard. If nothing answers, the conflict is a connection that's still
    /// open or in TIME_WAIT, and it is safe to retry with `SO_REUSEADDR`. A listener that appears between the probe
    /// and the retry could still be shared with, which is an acceptable gap for a local development server.
    ///
    /// Connections on other addresses, such as the link-local IPv6 connection `identityservicesd` keeps on port 1025,
    /// don't conflict with the first bind at all. `NWListener` refused to listen in that case, hence BSD sockets.
    private static func bind(
        _ descriptor: Int32,
        to address: SocketAddress,
        host: String,
        port: UInt16
    ) throws(SMTPServerError) {
        if address.withSockaddr({ Darwin.bind(descriptor, $0, $1) }) == 0 {
            return
        }
        let code = errno
        guard code == EADDRINUSE, port != 0 else {
            throw SMTPServerError(errno: code, operation: "bind", port: port)
        }

        let probeHosts: [String] =
            if !address.isWildcard {
                [host]
            } else if address.family == AF_INET {
                ["127.0.0.1"]
            } else {
                ["::1", "127.0.0.1"]
            }
        let probeAddresses = probeHosts.compactMap { SocketAddress(host: $0, port: port) }
        if probeAddresses.contains(where: hasListener) {
            throw .addressInUse(port: port)
        }

        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            throw SMTPServerError(errno: errno, operation: "setsockopt", port: port)
        }
        guard address.withSockaddr({ Darwin.bind(descriptor, $0, $1) }) == 0 else {
            throw SMTPServerError(errno: errno, operation: "bind", port: port)
        }
    }

    /// Whether something accepts TCP connections at `address`. A probe that doesn't complete counts as a listener, so
    /// an overloaded or unresponsive server is never shared with.
    private static func hasListener(at address: SocketAddress) -> Bool {
        let descriptor = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard configureNonBlocking(descriptor) else { return false }

        if address.withSockaddr({ connect(descriptor, $0, $1) }) == 0 {
            return true
        }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pollDescriptor, 1, probeTimeoutMilliseconds)
        guard ready > 0 else { return ready == 0 }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

    /// Makes `descriptor` non-blocking and close-on-exec. macOS has neither `SOCK_NONBLOCK`/`SOCK_CLOEXEC` nor `accept4`,
    /// so this is done right after the descriptor is created.
    static func configureNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0
            && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
            && fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
    }

    // MARK: - Accepting

    private static func acceptPending(on descriptor: Int32, port: UInt16, events: AsyncStream<Event>.Continuation) {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                let code = errno
                if code == EAGAIN {
                    return  // Nothing left to accept until the source fires again.
                }
                if code == EINTR || code == ECONNABORTED {
                    continue  // Transient, or the client gave up before we accepted it.
                }
                events.yield(.failed(SMTPServerError(errno: code, operation: "accept", port: port)))
                return
            }

            var enabled: Int32 = 1
            guard configureNonBlocking(client),
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
            else {
                close(client)
                continue
            }
            if case .terminated = events.yield(.accepted(client)) {
                close(client)
            }
        }
    }
}
