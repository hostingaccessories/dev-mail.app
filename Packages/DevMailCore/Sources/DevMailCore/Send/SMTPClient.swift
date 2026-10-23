import Darwin
import Foundation

public enum SMTPClientError: Error, Sendable, Equatable {
    /// The host isn't an IP address or `localhost`.
    case invalidHost(String)

    /// An envelope address contains characters that can't go in an SMTP command.
    case invalidAddress(String)

    case noRecipients
    case connectionFailed(host: String, port: UInt16, reason: String)
    case timedOut

    /// The server closed the connection mid-conversation.
    case connectionClosed

    /// The server answered `command` with an error or unexpected reply.
    case rejected(command: String, reply: String)
}

extension SMTPClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidHost(let host):
            "\"\(host)\" is not an IP address. Use an IPv4 or IPv6 address, or localhost."
        case .invalidAddress(let address):
            "\"\(address)\" can't be used as an envelope address."
        case .noRecipients:
            "The message has no recipients."
        case .connectionFailed(let host, let port, let reason):
            "Couldn't connect to \(SMTPClient.displayAddress(host: host, port: port)): \(reason)"
        case .timedOut:
            "The SMTP server didn't respond in time."
        case .connectionClosed:
            "The SMTP server closed the connection."
        case .rejected(let command, let reply):
            "The SMTP server rejected \(command): \(reply)"
        }
    }
}

/// A minimal blocking SMTP client for handing one message to a local server: no TLS and no authentication, which is
/// all Dev Mail needs.
public struct SMTPClient: Sendable {
    /// The server's reply once it accepted the message.
    public struct Delivery: Sendable, Equatable {
        public var reply: String

        /// The ID Dev Mail gave the message, read from its `250 OK: queued as <UUID>` reply.
        public var queuedID: UUID? {
            guard let range = reply.range(of: "queued as ") else { return nil }
            return UUID(uuidString: String(reply[range.upperBound...].prefix(36)))
        }
    }

    public var host: String
    public var port: UInt16
    public var timeout: Duration

    public init(host: String, port: UInt16, timeout: Duration = .seconds(30)) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    /// Sends one message. `data` may use LF or CRLF line endings; it is sent with CRLF and dot-stuffed.
    ///
    /// - Parameter sender: The envelope sender, or `nil` for the null reverse-path.
    public func send(_ data: Data, from sender: String?, to recipients: [String]) throws(SMTPClientError) -> Delivery {
        guard !recipients.isEmpty else { throw .noRecipients }
        for address in recipients + (sender.map { [$0] } ?? []) where !Self.isValidEnvelopeAddress(address) {
            throw .invalidAddress(address)
        }

        let descriptor = try connect()
        defer { close(descriptor) }
        var conversation = Conversation(descriptor: descriptor)

        try conversation.expect(220, after: "connecting")
        try conversation.command("EHLO localhost", expecting: 250)
        try conversation.command("MAIL FROM:<\(sender ?? "")>", expecting: 250)
        for recipient in recipients {
            try conversation.command("RCPT TO:<\(recipient)>", expecting: 250)
        }
        try conversation.command("DATA", expecting: 354)
        let reply = try conversation.send(Self.transmissionData(data), named: "the message", expecting: 250)
        // The message is accepted; a failed QUIT doesn't change that.
        _ = try? conversation.command("QUIT", expecting: 221)
        return Delivery(reply: reply)
    }

    // MARK: - Connecting

    private func connect() throws(SMTPClientError) -> Int32 {
        guard let address = SocketAddress(host: host, port: port) else { throw .invalidHost(host) }
        let descriptor = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw .connectionFailed(host: host, port: port, reason: BlockingSocket.describe(errno))
        }

        var enabled: Int32 = 1
        let connected =
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
            && BlockingSocket.setTimeout(timeout, on: descriptor)
            && address.withSockaddr({ Darwin.connect(descriptor, $0, $1) }) == 0
        guard connected else {
            let code = errno
            close(descriptor)
            if code == ETIMEDOUT || code == EAGAIN { throw .timedOut }
            throw .connectionFailed(host: host, port: port, reason: BlockingSocket.describe(code))
        }
        return descriptor
    }

    static func displayAddress(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Rejects anything that could end the command early or inject another one.
    static func isValidEnvelopeAddress(_ address: String) -> Bool {
        !address.isEmpty
            && address.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F && $0 != "<" && $0 != ">" }
    }

    // MARK: - Message data

    /// The message with CRLF line endings, dot-stuffed, ending in a line break and the terminating `.` line.
    static func transmissionData(_ data: Data) -> Data {
        var output = Data(capacity: data.count + data.count / 50 + 8)
        var atLineStart = true
        var previous: UInt8?
        for byte in data {
            switch byte {
            case UInt8(ascii: "\n"):
                if previous != UInt8(ascii: "\r") { output.append(UInt8(ascii: "\r")) }
                output.append(byte)
                atLineStart = true
            case UInt8(ascii: "\r"):
                output.append(byte)
                atLineStart = false
            default:
                // A bare CR not followed by LF becomes a line break too.
                if previous == UInt8(ascii: "\r") {
                    output.append(UInt8(ascii: "\n"))
                    atLineStart = true
                }
                if atLineStart, byte == UInt8(ascii: ".") { output.append(byte) }
                output.append(byte)
                atLineStart = false
            }
            previous = byte
        }
        if previous == UInt8(ascii: "\r") {
            output.append(UInt8(ascii: "\n"))
        } else if previous != nil, previous != UInt8(ascii: "\n") {
            output.append(contentsOf: Array("\r\n".utf8))
        }
        output.append(contentsOf: Array(".\r\n".utf8))
        return output
    }
}

/// Commands and replies on a connected socket.
private struct Conversation {
    let descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    mutating func command(_ line: String, expecting code: Int) throws(SMTPClientError) {
        let name = String(line.prefix { $0 != " " && $0 != ":" })
        _ = try send(Data((line + "\r\n").utf8), named: name, expecting: code)
    }

    /// Sends `data` and returns the text of the reply if it has `code`.
    mutating func send(_ data: Data, named name: String, expecting code: Int) throws(SMTPClientError) -> String {
        if let failure = BlockingSocket.writeAll(data, to: descriptor) {
            if failure == EAGAIN { throw .timedOut }
            throw .connectionClosed
        }
        return try expect(code, after: name)
    }

    @discardableResult
    mutating func expect(_ code: Int, after name: String) throws(SMTPClientError) -> String {
        let (replyCode, text) = try readReply()
        guard replyCode == code else { throw .rejected(command: name, reply: "\(replyCode) \(text)") }
        return text
    }

    /// Reads a complete reply, joining the text of a multi-line one.
    private mutating func readReply() throws(SMTPClientError) -> (Int, String) {
        var lines: [String] = []
        while true {
            let line = try readLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw .rejected(command: "the connection", reply: line)
            }
            lines.append(String(line.dropFirst(4)))
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " {
                return (code, lines.joined(separator: " "))
            }
        }
    }

    private mutating func readLine() throws(SMTPClientError) -> String {
        while true {
            if let lineFeed = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<lineFeed]
                buffer.removeSubrange(...lineFeed)
                let text = String(bytes: line, encoding: .utf8) ?? String(bytes: line, encoding: .isoLatin1) ?? ""
                return text.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
            switch BlockingSocket.read(from: descriptor) {
            case .success(let chunk?): buffer.append(chunk)
            case .success(nil): throw .connectionClosed
            case .failure(let error) where error.code == .EAGAIN: throw .timedOut
            case .failure: throw .connectionClosed
            }
        }
    }
}
