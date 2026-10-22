import Darwin

/// An IPv4 or IPv6 address and port in the form the BSD socket calls take.
struct SocketAddress: Sendable {
    private enum Storage: Sendable {
        case ipv4(sockaddr_in)
        case ipv6(sockaddr_in6)
    }

    private let storage: Storage

    /// Parses an IPv4 or IPv6 literal, or `localhost` (which means 127.0.0.1).
    ///
    /// Host names are deliberately not resolved: the server only needs to bind to loopback or a literal address, and
    /// resolving a name could pick an address the user didn't expect.
    init?(host: String, port: UInt16) {
        let literal = host.lowercased() == "localhost" ? "127.0.0.1" : host

        var ipv4 = sockaddr_in()
        if inet_pton(AF_INET, literal, &ipv4.sin_addr) == 1 {
            ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            ipv4.sin_family = sa_family_t(AF_INET)
            ipv4.sin_port = port.bigEndian
            storage = .ipv4(ipv4)
            return
        }

        var ipv6 = sockaddr_in6()
        if inet_pton(AF_INET6, literal, &ipv6.sin6_addr) == 1 {
            ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            ipv6.sin6_family = sa_family_t(AF_INET6)
            ipv6.sin6_port = port.bigEndian
            storage = .ipv6(ipv6)
            return
        }

        return nil
    }

    var family: Int32 {
        switch storage {
        case .ipv4: AF_INET
        case .ipv6: AF_INET6
        }
    }

    var isWildcard: Bool {
        switch storage {
        case .ipv4(let address):
            address.sin_addr.s_addr == INADDR_ANY
        case .ipv6(var address):
            withUnsafeBytes(of: &address.sin6_addr) { bytes in bytes.allSatisfy { $0 == 0 } }
        }
    }

    /// Calls `body` with a pointer to the address and its length, as `bind` and `connect` expect them.
    func withSockaddr<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        switch storage {
        case .ipv4(var address):
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .ipv6(var address):
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

    /// The port a bound socket ended up on, which differs from the requested one when that was `0`.
    static func localPort(of descriptor: Int32) -> UInt16? {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { return nil }

        switch Int32(address.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
        case AF_INET6:
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
        default:
            return nil
        }
    }
}
