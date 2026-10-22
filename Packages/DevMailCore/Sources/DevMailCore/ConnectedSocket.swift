import Darwin
import Dispatch
import Foundation
import Synchronization

/// Async reads and writes on a connected, non-blocking TCP socket, driven by Dispatch read and write sources.
///
/// One read and one write may be pending at a time (they can overlap). `cancel()` fails pending operations and closes
/// the descriptor once both sources have been cancelled, so it is closed exactly once and never while a source still
/// watches it. Every socket must eventually be cancelled: the sources hold on to it until then.
final class ConnectedSocket: Sendable {
    enum SocketError: Error, Sendable {
        case cancelled
        case system(errno: Int32)
    }

    private struct PendingWrite {
        let data: Data
        var written = 0
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var isCancelled = false
        var pendingRead: CheckedContinuation<Data?, any Error>?
        var pendingWrite: PendingWrite?
        // Sources start suspended and are only resumed while an operation waits on them.
        var isReadSourceSuspended = true
        var isWriteSourceSuspended = true
        var uncancelledSources = 2
    }

    private static let readChunkSize = 65_536

    private let descriptor: Int32
    private let readSource: any DispatchSourceRead
    private let writeSource: any DispatchSourceWrite
    private let state = Mutex(State())

    /// Takes ownership of `descriptor`, which must be a connected, non-blocking socket.
    init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)

        // The handlers keep the socket alive until the sources are cancelled, which releases them.
        readSource.setEventHandler { self.handleReadable() }
        writeSource.setEventHandler { self.handleWritable() }
        readSource.setCancelHandler { self.sourceCancelled() }
        writeSource.setCancelHandler { self.sourceCancelled() }
    }

    /// Reads the next available bytes, or returns `nil` when the peer has closed its side.
    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                guard !state.isCancelled else {
                    continuation.resume(throwing: SocketError.cancelled)
                    return
                }
                precondition(state.pendingRead == nil, "Only one read may be pending")
                state.pendingRead = continuation
                if state.isReadSourceSuspended {
                    state.isReadSourceSuspended = false
                    readSource.resume()
                }
            }
        }
    }

    /// Writes all of `data`, returning once the kernel has accepted the last byte.
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            state.withLock { state in
                guard !state.isCancelled else {
                    continuation.resume(throwing: SocketError.cancelled)
                    return
                }
                precondition(state.pendingWrite == nil, "Only one write may be pending")
                state.pendingWrite = PendingWrite(data: data, continuation: continuation)
                flushPendingWrite(&state)
            }
        }
    }

    /// Fails pending operations and closes the socket. Safe to call more than once.
    func cancel() {
        state.withLock { state in
            guard !state.isCancelled else { return }
            state.isCancelled = true

            state.pendingRead?.resume(throwing: SocketError.cancelled)
            state.pendingRead = nil
            state.pendingWrite?.continuation.resume(throwing: SocketError.cancelled)
            state.pendingWrite = nil

            // A suspended source never runs its cancel handler, and releasing one crashes.
            if state.isReadSourceSuspended {
                state.isReadSourceSuspended = false
                readSource.resume()
            }
            if state.isWriteSourceSuspended {
                state.isWriteSourceSuspended = false
                writeSource.resume()
            }
            readSource.cancel()
            writeSource.cancel()
        }
    }

    // MARK: - Source handlers

    private func handleReadable() {
        state.withLock { state in
            // Once cancelled, the descriptor may be closed at any moment and must not be touched.
            guard !state.isCancelled else { return }
            guard let continuation = state.pendingRead else {
                suspendReadSource(&state)
                return
            }

            var buffer = [UInt8](repeating: 0, count: Self.readChunkSize)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            let result: Result<Data?, any Error>
            if count > 0 {
                result = .success(Data(buffer[..<count]))
            } else if count == 0 {
                result = .success(nil)
            } else if errno == EAGAIN || errno == EINTR {
                return
            } else {
                result = .failure(SocketError.system(errno: errno))
            }

            state.pendingRead = nil
            suspendReadSource(&state)
            continuation.resume(with: result)
        }
    }

    private func handleWritable() {
        state.withLock { state in
            guard !state.isCancelled else { return }
            flushPendingWrite(&state)
        }
    }

    /// Writes as much of the pending write as the socket takes, and waits for the write source if it isn't done.
    private func flushPendingWrite(_ state: inout State) {
        guard var pending = state.pendingWrite else {
            suspendWriteSource(&state)
            return
        }

        while pending.written < pending.data.count {
            let count = pending.data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: pending.written),
                    bytes.count - pending.written
                )
            }
            if count >= 0 {
                pending.written += count
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                state.pendingWrite = pending
                if state.isWriteSourceSuspended {
                    state.isWriteSourceSuspended = false
                    writeSource.resume()
                }
                return
            } else {
                state.pendingWrite = nil
                suspendWriteSource(&state)
                pending.continuation.resume(throwing: SocketError.system(errno: errno))
                return
            }
        }

        state.pendingWrite = nil
        suspendWriteSource(&state)
        pending.continuation.resume()
    }

    private func suspendReadSource(_ state: inout State) {
        guard !state.isReadSourceSuspended else { return }
        state.isReadSourceSuspended = true
        readSource.suspend()
    }

    private func suspendWriteSource(_ state: inout State) {
        guard !state.isWriteSourceSuspended else { return }
        state.isWriteSourceSuspended = true
        writeSource.suspend()
    }

    private func sourceCancelled() {
        let isLast = state.withLock { state in
            state.uncancelledSources -= 1
            return state.uncancelledSources == 0
        }
        if isLast {
            close(descriptor)
        }
    }
}
