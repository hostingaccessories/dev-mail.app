import Darwin
import Foundation

public enum ControlClientError: Error, Sendable, Equatable {
    /// Nothing is listening on the control socket: the app isn't running.
    case notRunning

    /// The app took longer than the timeout to answer.
    case timedOut

    /// The app speaks a different protocol version.
    case versionMismatch(appVersion: Int)

    /// The app's reply couldn't be read.
    case invalidResponse

    case connectionFailed(reason: String)
}

extension ControlClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRunning:
            "Dev Mail isn't running."
        case .timedOut:
            "Dev Mail didn't respond in time."
        case .versionMismatch:
            "dev-mail and Dev Mail are different versions. Update them to the same version."
        case .invalidResponse:
            "Dev Mail sent a response that couldn't be read."
        case .connectionFailed(let reason):
            "Couldn't connect to Dev Mail: \(reason)"
        }
    }
}

/// Sends requests to the running app over its control socket. Calls block, which suits a command-line tool.
public struct ControlClient: Sendable {
    public let socketURL: URL
    public let timeout: Duration

    public init(socketURL: URL = ControlSocket.defaultURL, timeout: Duration = .seconds(30)) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    /// Whether the app is listening on the socket.
    public var isAppRunning: Bool {
        guard let address = UnixSocketAddress(path: socketURL.path(percentEncoded: false)),
            case .success(let descriptor) = address.connect()
        else { return false }
        close(descriptor)
        return true
    }

    public func send(_ request: ControlRequest) throws(ControlClientError) -> ControlResponse {
        let path = socketURL.path(percentEncoded: false)
        guard let address = UnixSocketAddress(path: path) else {
            throw .connectionFailed(reason: "The socket path is too long: \(path)")
        }

        let descriptor: Int32
        switch address.connect(timeout: timeout) {
        case .success(let connected):
            descriptor = connected
        case .failure(let error) where error.code == .ENOENT || error.code == .ECONNREFUSED:
            throw .notRunning
        case .failure(let error):
            throw .connectionFailed(reason: String(cString: strerror(error.code.rawValue)))
        }
        defer { close(descriptor) }

        let line: Data
        do {
            line = try ControlCoding.encode(ControlEnvelope(request))
        } catch {
            throw .connectionFailed(reason: error.localizedDescription)
        }
        try Self.writeAll(line, to: descriptor)
        return try Self.decode(Self.readAll(from: descriptor))
    }

    // MARK: - I/O

    private static func writeAll(_ data: Data, to descriptor: Int32) throws(ControlClientError) {
        let failure: Int32? = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, base + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return nil
        }
        if let failure {
            throw failure == EAGAIN ? .timedOut : .connectionFailed(reason: String(cString: strerror(failure)))
        }
    }

    /// Reads until the app closes the connection, which it does after its one response.
    private static func readAll(from descriptor: Int32) throws(ControlClientError) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if count == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                throw .timedOut
            } else {
                throw .connectionFailed(reason: String(cString: strerror(errno)))
            }
        }
    }

    private static func decode(_ data: Data) throws(ControlClientError) -> ControlResponse {
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(ControlEnvelopeVersion.self, from: data).version else {
            throw .invalidResponse
        }
        guard version == ControlProtocol.version else { throw .versionMismatch(appVersion: version) }
        guard let response = try? decoder.decode(ControlEnvelope<ControlResponse>.self, from: data).body else {
            throw .invalidResponse
        }
        return response
    }
}
