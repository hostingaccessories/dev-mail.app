/// Network settings for the local SMTP server.
public struct SMTPServerConfiguration: Sendable, Equatable {
    /// Address the server binds to. Defaults to loopback so the server is never exposed to the network.
    public var host: String

    /// TCP port the server listens on.
    public var port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = 1025) {
        self.host = host
        self.port = port
    }
}
