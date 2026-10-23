import Darwin
import Dispatch
import Foundation

/// Reasons the control server can't start.
public enum ControlServerError: Error, Sendable, Equatable {
    /// The socket path doesn't fit in a `sockaddr_un`.
    case pathTooLong(String)

    /// Another process, most likely another copy of the app, is already listening on the socket.
    case alreadyRunning

    /// Something other than a socket exists at the path, so it is left alone.
    case pathInUse(String)

    case failed(operation: String, reason: String)

    init(errno code: Int32, operation: String) {
        self = .failed(operation: operation, reason: String(cString: strerror(code)))
    }
}

extension ControlServerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            "The control socket path is too long: \(path)"
        case .alreadyRunning:
            "Another copy of Dev Mail is already listening for dev-mail commands."
        case .pathInUse(let path):
            "A file that isn't a socket is in the way of the control socket: \(path)"
        case .failed(let operation, let reason):
            "The control socket could not be opened: \(operation) failed: \(reason)"
        }
    }
}

/// Listens on a Unix domain socket for commands from the `dev-mail` tool and answers them with a handler.
///
/// Each connection carries one request line and one response line, then closes. The socket is created `0600` inside a
/// `0700` folder, and connections from other users are refused as well, since the messages can hold secrets such as
/// password reset links.
public actor ControlServer {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private struct ActiveConnection {
        let socket: ConnectedSocket
        let task: Task<Void, Never>
    }

    private enum ReadOutcome: Sendable {
        case line(Data)
        case closed
        case tooLong
        case timedOut
    }

    nonisolated public let socketURL: URL
    private let handler: Handler
    private let readTimeout: Duration
    private let queue = DispatchQueue(label: "com.hostingaccessories.DevMail.ControlServer")
    private var listener: UnixListener?
    private var listenerEventsTask: Task<Void, Never>?
    private var connections: [UUID: ActiveConnection] = [:]

    /// - Parameter readTimeout: How long a client may take to send its request.
    public init(
        socketURL: URL = ControlSocket.defaultURL,
        readTimeout: Duration = .seconds(5),
        handler: @escaping Handler
    ) {
        self.socketURL = socketURL
        self.readTimeout = readTimeout
        self.handler = handler
    }

    /// Creates the socket and starts accepting connections. Does nothing if already started.
    ///
    /// A socket left behind by an app that didn't quit cleanly is replaced, but one that another process still
    /// listens on is not.
    public func start() throws(ControlServerError) {
        guard listener == nil else { return }

        let path = socketURL.path(percentEncoded: false)
        guard let address = UnixSocketAddress(path: path) else { throw .pathTooLong(path) }
        try Self.prepareDirectory(socketURL.deletingLastPathComponent())
        try Self.removeStaleSocket(at: address)

        let (events, eventsContinuation) = AsyncStream.makeStream(of: Int32.self)
        let listener = try UnixListener(address: address, queue: queue, events: eventsContinuation)
        self.listener = listener
        listenerEventsTask = Task {
            for await descriptor in events {
                self.accept(descriptor, from: listener)
            }
        }
    }

    /// Stops listening, closes open connections and removes the socket file.
    public func stop() async {
        guard let listener else { return }
        self.listener = nil
        listener.cancel()
        await listenerEventsTask?.value
        listenerEventsTask = nil

        let active = Array(connections.values)
        for entry in active {
            entry.socket.cancel()
        }
        for entry in active {
            await entry.task.value
        }
        unlink(socketURL.path(percentEncoded: false))
    }

    // MARK: - Setup

    private static func prepareDirectory(_ directory: URL) throws(ControlServerError) {
        let path = directory.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            throw .failed(operation: "mkdir", reason: error.localizedDescription)
        }
    }

    private static func removeStaleSocket(at address: UnixSocketAddress) throws(ControlServerError) {
        var info = stat()
        guard lstat(address.path, &info) == 0 else {
            guard errno == ENOENT else { throw ControlServerError(errno: errno, operation: "lstat") }
            return
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw .pathInUse(address.path) }

        if case .success(let descriptor) = address.connect() {
            close(descriptor)
            throw .alreadyRunning
        }
        guard unlink(address.path) == 0 || errno == ENOENT else {
            throw ControlServerError(errno: errno, operation: "unlink")
        }
    }

    // MARK: - Connections

    /// Takes ownership of an accepted client socket.
    private func accept(_ descriptor: Int32, from source: UnixListener) {
        guard source === listener, Self.isSameUser(descriptor) else {
            close(descriptor)
            return
        }

        let socket = ConnectedSocket(descriptor: descriptor, queue: queue)
        let id = UUID()
        let task = Task {
            await self.serve(socket)
            self.connectionFinished(id)
        }
        connections[id] = ActiveConnection(socket: socket, task: task)
    }

    private func connectionFinished(_ id: UUID) {
        connections[id] = nil
    }

    /// Whether the peer runs as the same user as this process.
    nonisolated private static func isSameUser(_ descriptor: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
    }

    /// Reads one request, answers it and closes the connection.
    nonisolated private func serve(_ socket: ConnectedSocket) async {
        defer { socket.cancel() }

        let response: ControlResponse
        switch await readRequest(from: socket) {
        case .line(let line):
            response = await respond(to: line)
        case .tooLong:
            response = .failure(reason: "The request is too long.")
        case .closed, .timedOut:
            return
        }

        guard let data = try? ControlCoding.encode(ControlEnvelope(response)) else { return }
        try? await socket.write(data)
    }

    nonisolated private func respond(to line: Data) async -> ControlResponse {
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(ControlEnvelopeVersion.self, from: line).version else {
            return .failure(reason: "The request is not valid.")
        }
        guard version == ControlProtocol.version else {
            return .failure(reason: "dev-mail and Dev Mail are different versions. Update them to the same version.")
        }
        guard let request = try? decoder.decode(ControlEnvelope<ControlRequest>.self, from: line).body else {
            return .failure(reason: "The request is not valid.")
        }
        return await handler(request)
    }

    nonisolated private func readRequest(from socket: ConnectedSocket) async -> ReadOutcome {
        let timeout = readTimeout
        return await withTaskGroup(of: ReadOutcome.self) { group in
            group.addTask { await Self.readLine(from: socket) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let outcome = await group.next() ?? .closed
            group.cancelAll()
            // The read isn't cancellable, so close the socket to end it.
            if case .timedOut = outcome {
                socket.cancel()
            }
            return outcome
        }
    }

    /// Reads up to the first line feed. A request without one is taken as complete when the client closes its side.
    nonisolated private static func readLine(from socket: ConnectedSocket) async -> ReadOutcome {
        var buffer = Data()
        while true {
            if let lineFeed = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return .line(buffer[..<lineFeed])
            }
            guard buffer.count <= ControlCoding.maxRequestLength else { return .tooLong }
            guard let chunk = try? await socket.read() else {
                return buffer.isEmpty ? .closed : .line(buffer)
            }
            buffer.append(chunk)
        }
    }
}

/// A non-blocking Unix domain listening socket that reports accepted client sockets.
///
/// The socket is closed exactly once, by the accept source's cancel handler, which also finishes the event stream.
/// Accepted descriptors belong to whoever receives them; one that can't be delivered is closed here.
private final class UnixListener: Sendable {
    private let source: any DispatchSourceRead

    init(address: UnixSocketAddress, queue: DispatchQueue, events: AsyncStream<Int32>.Continuation)
        throws(ControlServerError)
    {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlServerError(errno: errno, operation: "socket") }
        do throws(ControlServerError) {
            guard ListeningSocket.configureNonBlocking(descriptor) else {
                throw ControlServerError(errno: errno, operation: "fcntl")
            }
            guard address.withSockaddr({ bind(descriptor, $0, $1) }) == 0 else {
                throw ControlServerError(errno: errno, operation: "bind")
            }
            // The folder is already private; this also keeps the socket itself from other users.
            guard chmod(address.path, 0o600) == 0 else {
                let code = errno
                unlink(address.path)
                throw ControlServerError(errno: code, operation: "chmod")
            }
            guard listen(descriptor, SOMAXCONN) == 0 else {
                let code = errno
                unlink(address.path)
                throw ControlServerError(errno: code, operation: "listen")
            }
        } catch {
            close(descriptor)
            throw error
        }

        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            Self.acceptPending(on: descriptor, events: events)
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

    func cancel() {
        source.cancel()
    }

    private static func acceptPending(on descriptor: Int32, events: AsyncStream<Int32>.Continuation) {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                // EAGAIN means nothing is left until the source fires again. Other errors are retried then too: the
                // control socket is a convenience, so it never takes the app down.
                return
            }

            var enabled: Int32 = 1
            guard ListeningSocket.configureNonBlocking(client),
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
            else {
                close(client)
                continue
            }
            if case .terminated = events.yield(client) {
                close(client)
            }
        }
    }
}
