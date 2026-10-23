import Darwin
import Foundation

/// Blocking socket I/O for the clients a command-line tool uses, where waiting on a call is fine. Failures are
/// returned as `errno` values; `EAGAIN` means a timeout set with `setTimeout(_:on:)` expired.
enum BlockingSocket {
    /// Limits how long each read and write may wait.
    static func setTimeout(_ timeout: Duration, on descriptor: Int32) -> Bool {
        let (seconds, attoseconds) = timeout.components
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        return setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, size) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, size) == 0
    }

    /// Writes all of `data`, returning the `errno` of a failed write.
    static func writeAll(_ data: Data, to descriptor: Int32) -> Int32? {
        data.withUnsafeBytes { bytes in
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
    }

    /// The next available bytes, `nil` once the peer has closed its side, or the `errno` of a failed read.
    static func read(from descriptor: Int32) -> Result<Data?, POSIXError> {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { return .success(Data(buffer[..<count])) }
            if count == 0 { return .success(nil) }
            if errno != EINTR { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        }
    }

    static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
