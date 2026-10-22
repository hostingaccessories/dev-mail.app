import Foundation
import Network

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

    private enum ListenerEvent: Sendable {
        case ready(port: UInt16?)
        case failed(NWError)
        case newConnection(NWConnection)
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
    private var listener: NWListener?
    private var listenerEvents: AsyncStream<ListenerEvent>.Continuation?
    private var listenerEventsTask: Task<Void, Never>?
    private var pendingStart: CheckedContinuation<Void, any Error>?
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

        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(configuration.host),
                port: NWEndpoint.Port(rawValue: configuration.port) ?? .any
            )
            // Lets the server restart on the same port while old connections sit in TIME_WAIT.
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters)
        } catch {
            let serverError = SMTPServerError(error, port: configuration.port)
            state = .failed(serverError)
            throw serverError
        }

        let (events, eventsContinuation) = AsyncStream.makeStream(of: ListenerEvent.self)
        listener.stateUpdateHandler = { [weak listener] newState in
            switch newState {
            case .ready:
                eventsContinuation.yield(.ready(port: listener?.port?.rawValue))
            case .failed(let error), .waiting(let error):
                // A listener only waits when it can't bind, which for a local server is as good as failed.
                eventsContinuation.yield(.failed(error))
            case .cancelled:
                eventsContinuation.finish()
            case .setup:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            eventsContinuation.yield(.newConnection(connection))
        }

        self.listener = listener
        listenerEvents = eventsContinuation
        listenerEventsTask = Task {
            for await event in events {
                self.handle(event, from: listener)
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            pendingStart = continuation
            listener.start(queue: queue)
        }
    }

    /// Stops listening and closes every open connection. Returns once all connections have finished.
    public func stop() async {
        stopListening()
        pendingStart?.resume(throwing: CancellationError())
        pendingStart = nil

        let active = Array(connections.values)
        for entry in active {
            entry.connection.cancel()
        }
        for entry in active {
            await entry.task.value
        }
        if let listenerEventsTask {
            self.listenerEventsTask = nil
            await listenerEventsTask.value
        }

        // start() may have been called again while this was waiting.
        if listener == nil {
            state = .stopped
        }
    }

    // MARK: - Listener events

    private func handle(_ event: ListenerEvent, from source: NWListener) {
        guard source === listener else {
            if case .newConnection(let connection) = event {
                connection.cancel()
            }
            return
        }

        switch event {
        case .ready(let port):
            state = .listening(host: configuration.host, port: port ?? configuration.port)
            pendingStart?.resume()
            pendingStart = nil
        case .failed(let error):
            fail(with: SMTPServerError(error, port: configuration.port))
        case .newConnection(let connection):
            accept(connection)
        }
    }

    private func fail(with error: SMTPServerError) {
        stopListening()
        for entry in connections.values {
            entry.connection.cancel()
        }
        state = .failed(error)
        pendingStart?.resume(throwing: error)
        pendingStart = nil
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        listenerEvents?.finish()
        listenerEvents = nil
    }

    // MARK: - Connections

    private func accept(_ nwConnection: NWConnection) {
        guard connections.count < configuration.maxConnections else {
            reject(nwConnection)
            return
        }

        let connection = SMTPConnection(
            connection: nwConnection,
            configuration: configuration,
            queue: queue,
            deliver: deliver
        )
        let id = connection.id
        let task = Task {
            await connection.run()
            self.connectionFinished(id)
        }
        connections[id] = ActiveConnection(connection: connection, task: task)
    }

    /// Turns away a client over the connection limit without starting a session for it.
    nonisolated private func reject(_ connection: NWConnection) {
        let reply = SMTPReply(421, "Too many connections, try again later")
        connection.start(queue: queue)
        connection.send(
            content: Data(reply.wireFormat.utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func connectionFinished(_ id: UUID) {
        connections[id] = nil
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
