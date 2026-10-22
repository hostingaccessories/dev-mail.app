import Foundation

/// Runs the SMTP conversation for one client: reads from the socket, feeds an `SMTPSession` and writes its replies.
final class SMTPConnection: Sendable {
    private enum ReceiveOutcome: Sendable {
        case data(Data)
        case endOfStream
        case timedOut
    }

    let id = UUID()
    private let socket: ConnectedSocket
    private let configuration: SMTPServerConfiguration
    private let deliver: SMTPServer.DeliveryHandler

    /// Takes ownership of `socket`, which is closed when `run()` ends or the connection is cancelled.
    init(
        socket: ConnectedSocket,
        configuration: SMTPServerConfiguration,
        deliver: @escaping SMTPServer.DeliveryHandler
    ) {
        self.socket = socket
        self.configuration = configuration
        self.deliver = deliver
    }

    /// Runs until the client quits, disconnects, times out or the connection is cancelled.
    func run() async {
        defer { socket.cancel() }

        var session = SMTPSession(configuration: configuration)
        do {
            try await send([session.greeting])
            while !session.isClosed {
                guard case .data(let bytes) = try await receiveWithIdleTimeout() else { return }

                var replies: [SMTPReply] = []
                for event in session.receive(bytes) {
                    switch event {
                    case .reply(let reply):
                        replies.append(reply)
                    case .deliver(let message):
                        // Deliver before sending the 250 that follows, so an accepted message has been handed off.
                        await deliver(message)
                    case .close:
                        break
                    }
                }
                if !replies.isEmpty {
                    try await send(replies)
                }
            }
        } catch {
            // The client went away or the connection was cancelled; there is nobody left to report to.
        }
    }

    /// Closes the connection, ending `run()`.
    func cancel() {
        socket.cancel()
    }

    // MARK: - I/O

    private func receiveWithIdleTimeout() async throws -> ReceiveOutcome {
        try await withThrowingTaskGroup(of: ReceiveOutcome.self) { group in
            group.addTask { try await self.receive() }
            group.addTask {
                try await Task.sleep(for: self.configuration.idleTimeout)
                return .timedOut
            }
            defer { group.cancelAll() }

            do {
                let outcome = try await group.next() ?? .endOfStream
                if case .timedOut = outcome {
                    try? await send([SMTPReply(421, "Idle timeout, closing connection")])
                    // Cancelling completes the pending receive so the task group can finish.
                    socket.cancel()
                }
                return outcome
            } catch {
                socket.cancel()
                throw error
            }
        }
    }

    private func receive() async throws -> ReceiveOutcome {
        if let bytes = try await socket.read() {
            .data(bytes)
        } else {
            .endOfStream
        }
    }

    private func send(_ replies: [SMTPReply]) async throws {
        try await socket.write(Data(replies.map(\.wireFormat).joined().utf8))
    }
}
