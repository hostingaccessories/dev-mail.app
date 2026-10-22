import Darwin
import Foundation

/// A local SMTP server that accepts every message and passes it to a delivery handler.
///
/// ```swift
/// let server = SMTPServer(configuration: SMTPServerConfiguration()) { message in
///     await store.save(message)
/// }
/// try await server.start()
/// ```
public actor SMTPServer {
    /// Called once for each accepted message, before the client is told it was accepted.
    public typealias DeliveryHandler = @Sendable (ReceivedMessage) async -> Void

    public enum State: Sendable, Equatable {
        case stopped
        case listening(host: String, port: UInt16)
        case failed(SMTPServerError)
    }

    private struct ActiveConnection {
        let connection: SMTPConnection
        let task: Task<Void, Never>
    }

    nonisolated public let configuration: SMTPServerConfiguration

    /// The current state. Use `stateUpdates()` to observe changes.
    public private(set) var state = State.stopped {
        didSet {
            guard state != oldValue else { return }
            for observer in observers.values {
                observer.yield(state)
            }
        }
    }

    private let deliver: DeliveryHandler
    private let queue = DispatchQueue(label: "com.hostingaccessories.DevMail.SMTPServer")
    private var listener: ListeningSocket?
    private var listenerEventsTask: Task<Void, Never>?
    private var connections: [UUID: ActiveConnection] = [:]
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]

    public init(configuration: SMTPServerConfiguration = SMTPServerConfiguration(), deliver: @escaping DeliveryHandler)
    {
        self.configuration = configuration
        self.deliver = deliver
    }

    /// A stream that yields the current state immediately, then every change until the stream is dropped.
    public func stateUpdates() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(state)
        return stream
    }

    /// Starts listening and returns once the server is accepting connections. Does nothing if already started.
    ///
    /// - Throws: `SMTPServerError` if the server can't listen on the configured host and port.
    public func start() async throws {
        guard listener == nil else { return }

        let (events, eventsContinuation) = AsyncStream.makeStream(of: ListeningSocket.Event.self)
        let listener: ListeningSocket
        do {
            listener = try ListeningSocket(
                host: configuration.host,
                port: configuration.port,
                queue: queue,
                events: eventsContinuation
            )
        } catch {
            state = .failed(error)
            throw error
        }

        self.listener = listener
        // Ends once the listener is cancelled and every connection it accepted has been handled.
        listenerEventsTask = Task {
            for await event in events {
                self.handle(event, from: listener)
            }
        }
        state = .listening(host: configuration.host, port: listener.port)
    }

    /// Stops listening and closes every open connection. Returns once the listening socket is closed, so new
    /// connections are refused, and all connections have finished.
    public func stop() async {
        let listenerEventsTask = listenerEventsTask
        self.listenerEventsTask = nil
        stopListening()

        // The event stream finishes in the listener's cancel handler, right after it closes the socket, so this also
        // waits for the port to be released. Connections accepted before that are closed, as the listener is gone.
        await listenerEventsTask?.value

        let active = Array(connections.values)
        for entry in active {
            entry.connection.cancel()
        }
        for entry in active {
            await entry.task.value
        }

        // start() may have been called again while this was waiting.
        if listener == nil {
            state = .stopped
        }
    }

    // MARK: - Listener events

    private func handle(_ event: ListeningSocket.Event, from source: ListeningSocket) {
        guard source === listener else {
            if case .accepted(let descriptor) = event {
                close(descriptor)
            }
            return
        }

        switch event {
        case .accepted(let descriptor):
            accept(descriptor)
        case .failed(let error):
            fail(with: error)
        }
    }

    private func fail(with error: SMTPServerError) {
        stopListening()
        for entry in connections.values {
            entry.connection.cancel()
        }
        state = .failed(error)
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connections

    /// Takes ownership of an accepted client socket.
    private func accept(_ descriptor: Int32) {
        guard connections.count < configuration.maxConnections else {
            reject(descriptor)
            return
        }

        let connection = SMTPConnection(
            socket: ConnectedSocket(descriptor: descriptor, queue: queue),
            configuration: configuration,
            deliver: deliver
        )
        let id = connection.id
        let task = Task {
            await connection.run()
            self.connectionFinished(id)
        }
        connections[id] = ActiveConnection(connection: connection, task: task)
    }

    /// Turns away a client over the connection limit without starting a session for it, and closes its socket.
    ///
    /// The reply fits in a new socket's empty send buffer, so one non-blocking write is enough. If it somehow isn't,
    /// the client just sees the connection close.
    nonisolated private func reject(_ descriptor: Int32) {
        let reply = Array(SMTPReply(421, "Too many connections, try again later").wireFormat.utf8)
        _ = reply.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
    }

    private func connectionFinished(_ id: UUID) {
        connections[id] = nil
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
