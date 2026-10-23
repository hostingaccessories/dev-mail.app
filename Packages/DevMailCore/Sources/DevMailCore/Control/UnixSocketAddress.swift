import Darwin
import Foundation

/// The control socket's location and a `sockaddr_un` for it.
public enum ControlSocket {
    /// `~/Library/Application Support/Dev Mail/control.sock`, next to the messages folder.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Dev Mail/control.sock", directoryHint: .notDirectory)
    }
}

/// A Unix domain socket path in the form `bind` and `connect` take.
struct UnixSocketAddress: Sendable {
    let path: String
    private let address: sockaddr_un

    /// Fails if `path` doesn't fit in `sun_path` (104 bytes on macOS, including the terminating zero).
    init?(path: String) {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else { return nil }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        self.path = path
        self.address = address
    }

    func withSockaddr<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Connects a new blocking, close-on-exec socket to this address. Returns the descriptor, or the error of the
    /// failed call. Connecting to a Unix socket never waits: it fails at once when nothing is listening.
    ///
    /// - Parameter timeout: Limits each read and write. It is set before connecting because macOS refuses socket
    ///   options once the peer has closed, which a quick server can do before a later `setsockopt`.
    func connect(timeout: Duration? = nil) -> Result<Int32, POSIXError> {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }

        var enabled: Int32 = 1
        let connected =
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
            && timeout.map { Self.setTimeout($0, on: descriptor) } ?? true
            && withSockaddr({ Darwin.connect(descriptor, $0, $1) }) == 0
        guard connected else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            return .failure(error)
        }
        return .success(descriptor)
    }

    private static func setTimeout(_ timeout: Duration, on descriptor: Int32) -> Bool {
        let (seconds, attoseconds) = timeout.components
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        return setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, size) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, size) == 0
    }
}
