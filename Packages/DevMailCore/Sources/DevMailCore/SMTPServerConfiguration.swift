/// Network settings and limits for the local SMTP server.
public struct SMTPServerConfiguration: Sendable, Equatable {
    /// Address the server binds to. Defaults to loopback so the server is never exposed to the network.
    public var host: String

    /// TCP port the server listens on. Use `0` to let the system pick an unused port.
    public var port: UInt16

    /// Maximum number of clients connected at the same time. Extra clients get a `421` reply and are disconnected.
    public var maxConnections: Int

    /// How long a connection may stay silent before the server closes it.
    public var idleTimeout: Duration

    /// Maximum size of a message's content in bytes, advertised to clients with the `SIZE` extension.
    public var maxMessageSize: Int

    /// Maximum length in bytes of a command line, excluding the CRLF.
    ///
    /// Lines inside message content are bounded by `maxMessageSize` instead, so long lines in a message body are
    /// accepted.
    public var maxCommandLineLength: Int

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 1025,
        maxConnections: Int = 32,
        idleTimeout: Duration = .seconds(300),
        maxMessageSize: Int = 25 * 1024 * 1024,
        maxCommandLineLength: Int = 4096
    ) {
        self.host = host
        self.port = port
        self.maxConnections = maxConnections
        self.idleTimeout = idleTimeout
        self.maxMessageSize = maxMessageSize
        self.maxCommandLineLength = maxCommandLineLength
    }
}
