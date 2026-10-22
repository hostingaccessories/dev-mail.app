import Foundation

/// The SMTP conversation for one connection, independent of any networking.
///
/// Feed it the bytes read from the client with `receive(_:)` and act on the returned events in order: send replies,
/// deliver messages and close the connection when asked. It accepts every message and every recipient, and accepts any
/// credentials for `AUTH PLAIN` and `AUTH LOGIN` without keeping them.
struct SMTPSession {
    enum Event: Sendable, Equatable {
        case reply(SMTPReply)
        case deliver(ReceivedMessage)
        case close
    }

    /// Upper bound on `RCPT TO` per message so one transaction can't grow without limit.
    static let maxRecipients = 1000

    private enum Mode {
        case command
        case data
        case authPlainResponse
        case authLoginUsername
        case authLoginPassword
        case closed
    }

    private struct Transaction {
        var sender: String?
        var recipients: [String] = []
    }

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let dot = UInt8(ascii: ".")

    private let hostname: String
    private let maxMessageSize: Int
    private let maxCommandLineLength: Int

    private var mode = Mode.command
    private var greeted = false
    private var authenticated = false
    private var transaction: Transaction?

    /// Bytes received but not yet terminated by a line feed.
    private var pendingBytes: [UInt8] = []

    private var messageData = Data()
    private var messageExceedsLimit = false

    /// Set when an oversized partial line was dropped, so its remainder isn't mistaken for a new line.
    private var discardingPartialLine = false

    init(configuration: SMTPServerConfiguration, hostname: String = "localhost") {
        self.hostname = hostname
        self.maxMessageSize = configuration.maxMessageSize
        self.maxCommandLineLength = configuration.maxCommandLineLength
    }

    /// The reply to send as soon as the client connects.
    var greeting: SMTPReply {
        SMTPReply(220, "\(hostname) ESMTP Dev Mail ready")
    }

    /// Whether the session has ended and the connection should be closed.
    var isClosed: Bool {
        mode == .closed
    }

    /// Processes bytes from the client, which may contain any number of complete or partial lines.
    mutating func receive(_ bytes: Data) -> [Event] {
        guard mode != .closed else { return [] }
        pendingBytes.append(contentsOf: bytes)

        var events: [Event] = []
        var lineStart = pendingBytes.startIndex
        while mode != .closed,
            let lineFeedIndex = pendingBytes[lineStart...].firstIndex(of: Self.lineFeed)
        {
            var lineEnd = lineFeedIndex
            if lineEnd > lineStart, pendingBytes[lineEnd - 1] == Self.carriageReturn {
                lineEnd -= 1
            }
            events += handleLine(pendingBytes[lineStart..<lineEnd])
            lineStart = lineFeedIndex + 1
        }

        if mode == .closed {
            pendingBytes = []
            return events
        }
        // Removing consumed bytes once per call, not once per line, keeps large chunks linear.
        pendingBytes.removeSubrange(..<lineStart)
        events += enforcePartialLineLimit()
        return events
    }

    // MARK: - Lines

    private mutating func handleLine(_ line: ArraySlice<UInt8>) -> [Event] {
        switch mode {
        case .command:
            guard line.count <= maxCommandLineLength else { return lineTooLong() }
            guard let command = String(bytes: line, encoding: .utf8) else {
                return [.reply(SMTPReply(500, "Command contains invalid characters"))]
            }
            return handleCommand(command)
        case .data:
            return handleDataLine(line)
        case .authPlainResponse, .authLoginUsername, .authLoginPassword:
            guard line.count <= maxCommandLineLength else { return lineTooLong() }
            // Invalid UTF-8 can't be valid base64, so an empty response gets the same 501 reply.
            return handleAuthResponse(String(bytes: line, encoding: .utf8) ?? "")
        case .closed:
            return []
        }
    }

    /// Stops a client from making us buffer an unterminated line without limit.
    private mutating func enforcePartialLineLimit() -> [Event] {
        switch mode {
        case .data:
            // Allow room for a stuffed leading dot and the CRLF on top of the remaining message budget.
            let limit = messageExceedsLimit ? maxCommandLineLength : maxMessageSize - messageData.count + 3
            if pendingBytes.count > limit {
                markMessageTooLarge()
                pendingBytes = []
                discardingPartialLine = true
            }
            return []
        case .command, .authPlainResponse, .authLoginUsername, .authLoginPassword:
            // Allow one extra byte for a carriage return still waiting for its line feed.
            return pendingBytes.count > maxCommandLineLength + 1 ? lineTooLong() : []
        case .closed:
            return []
        }
    }

    private mutating func lineTooLong() -> [Event] {
        close(with: SMTPReply(500, "Line too long"))
    }

    private mutating func close(with reply: SMTPReply) -> [Event] {
        mode = .closed
        pendingBytes = []
        return [.reply(reply), .close]
    }

    // MARK: - Commands

    private mutating func handleCommand(_ line: String) -> [Event] {
        let (verb, argument) = SMTPCommandParser.splitCommand(line)
        switch verb {
        case "HELO":
            return [.reply(helo(argument))]
        case "EHLO":
            return [.reply(ehlo(argument))]
        case "MAIL":
            return [.reply(mail(argument))]
        case "RCPT":
            return [.reply(rcpt(argument))]
        case "DATA":
            return [.reply(data(argument))]
        case "AUTH":
            return [.reply(auth(argument))]
        case "QUIT":
            return close(with: SMTPReply(221, "Bye"))
        default:
            return [.reply(otherCommand(verb, argument))]
        }
    }

    /// Commands that don't affect the session beyond resetting the transaction, and unknown commands.
    private mutating func otherCommand(_ verb: String, _ argument: String) -> SMTPReply {
        switch verb {
        case "RSET":
            transaction = nil
            return SMTPReply(250, "OK")
        case "NOOP":
            return SMTPReply(250, "OK")
        case "VRFY":
            guard !argument.isEmpty else { return SMTPReply(501, "Syntax: VRFY <address>") }
            return SMTPReply(252, "Cannot VRFY user, but will accept message and attempt delivery")
        case "EXPN", "HELP", "TURN", "ETRN", "STARTTLS":
            return SMTPReply(502, "Command not implemented")
        default:
            return SMTPReply(500, "Command unrecognized")
        }
    }

    private mutating func helo(_ argument: String) -> SMTPReply {
        guard !argument.isEmpty else { return SMTPReply(501, "Syntax: HELO <hostname>") }
        greeted = true
        transaction = nil
        return SMTPReply(250, hostname)
    }

    private mutating func ehlo(_ argument: String) -> SMTPReply {
        guard !argument.isEmpty else { return SMTPReply(501, "Syntax: EHLO <hostname>") }
        greeted = true
        transaction = nil
        // STARTTLS is deliberately not advertised.
        return SMTPReply(
            250,
            "\(hostname) Hello",
            "SIZE \(maxMessageSize)",
            "8BITMIME",
            "PIPELINING",
            "AUTH PLAIN LOGIN"
        )
    }

    private mutating func mail(_ argument: String) -> SMTPReply {
        guard greeted else { return SMTPReply(503, "Send HELO or EHLO first") }
        guard transaction == nil else { return SMTPReply(503, "Sender already specified") }
        guard let path = SMTPCommandParser.parsePath(argument, prefix: "FROM:") else {
            return SMTPReply(501, "Syntax: MAIL FROM:<address>")
        }
        if let declaredSize = SMTPCommandParser.sizeParameter(path.parameters), declaredSize > maxMessageSize {
            return SMTPReply(552, "Message size exceeds fixed maximum message size")
        }
        transaction = Transaction(sender: path.address.isEmpty ? nil : path.address)
        return SMTPReply(250, "OK")
    }

    private mutating func rcpt(_ argument: String) -> SMTPReply {
        guard transaction != nil else { return SMTPReply(503, "Need MAIL command first") }
        guard let path = SMTPCommandParser.parsePath(argument, prefix: "TO:"), !path.address.isEmpty else {
            return SMTPReply(501, "Syntax: RCPT TO:<address>")
        }
        guard (transaction?.recipients.count ?? 0) < Self.maxRecipients else {
            return SMTPReply(452, "Too many recipients")
        }
        transaction?.recipients.append(path.address)
        return SMTPReply(250, "OK")
    }

    private mutating func data(_ argument: String) -> SMTPReply {
        guard argument.isEmpty else { return SMTPReply(501, "Syntax: DATA") }
        guard let transaction else { return SMTPReply(503, "Need MAIL command first") }
        guard !transaction.recipients.isEmpty else { return SMTPReply(503, "Need RCPT command first") }
        mode = .data
        return SMTPReply(354, "End data with <CR><LF>.<CR><LF>")
    }

    // MARK: - Message content

    private mutating func handleDataLine(_ line: ArraySlice<UInt8>) -> [Event] {
        if discardingPartialLine {
            discardingPartialLine = false
            return []
        }
        if line.count == 1, line.first == Self.dot {
            return finishMessage()
        }
        guard !messageExceedsLimit else { return [] }

        // Undo dot-stuffing (RFC 5321 section 4.5.2).
        let content = line.first == Self.dot ? line.dropFirst() : line
        guard messageData.count + content.count + 2 <= maxMessageSize else {
            markMessageTooLarge()
            return []
        }
        messageData.append(contentsOf: content)
        messageData.append(contentsOf: [Self.carriageReturn, Self.lineFeed])
        return []
    }

    private mutating func markMessageTooLarge() {
        messageExceedsLimit = true
        messageData = Data()
    }

    private mutating func finishMessage() -> [Event] {
        defer {
            mode = .command
            transaction = nil
            messageData = Data()
            messageExceedsLimit = false
        }
        guard !messageExceedsLimit, let transaction else {
            return [.reply(SMTPReply(552, "Message size exceeds fixed maximum message size"))]
        }
        let message = ReceivedMessage(
            envelopeSender: transaction.sender,
            recipients: transaction.recipients,
            data: messageData
        )
        return [.deliver(message), .reply(SMTPReply(250, "OK: queued as \(message.id.uuidString)"))]
    }

}

// MARK: - Authentication

extension SMTPSession {

    private mutating func auth(_ argument: String) -> SMTPReply {
        guard greeted else { return SMTPReply(503, "Send EHLO first") }
        guard !authenticated else { return SMTPReply(503, "Already authenticated") }
        guard transaction == nil else { return SMTPReply(503, "AUTH not allowed during a mail transaction") }

        let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
        let mechanism = parts.first?.uppercased() ?? ""
        let initialResponse = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil

        switch mechanism {
        case "PLAIN":
            guard let initialResponse else {
                mode = .authPlainResponse
                return SMTPReply(334, "")
            }
            return completeAuthentication(initialResponse)
        case "LOGIN":
            guard let initialResponse else {
                mode = .authLoginUsername
                return SMTPReply(334, "VXNlcm5hbWU6")  // "Username:"
            }
            guard SMTPCommandParser.isValidBase64(initialResponse) else { return SMTPReply(501, "Invalid base64 data") }
            mode = .authLoginPassword
            return SMTPReply(334, "UGFzc3dvcmQ6")  // "Password:"
        case "":
            return SMTPReply(501, "Syntax: AUTH <mechanism>")
        default:
            return SMTPReply(504, "Unrecognized authentication type")
        }
    }

    private mutating func handleAuthResponse(_ line: String) -> [Event] {
        let response = line.trimmingCharacters(in: .whitespaces)
        let currentMode = mode
        mode = .command
        if response == "*" {
            return [.reply(SMTPReply(501, "Authentication cancelled"))]
        }
        switch currentMode {
        case .authLoginUsername:
            guard SMTPCommandParser.isValidBase64(response) else {
                return [.reply(SMTPReply(501, "Invalid base64 data"))]
            }
            mode = .authLoginPassword
            return [.reply(SMTPReply(334, "UGFzc3dvcmQ6"))]
        default:
            return [.reply(completeAuthentication(response))]
        }
    }

    /// Accepts any well-formed credentials. They are only checked for valid base64 and never stored or logged.
    private mutating func completeAuthentication(_ response: String) -> SMTPReply {
        // "=" is an empty initial response (RFC 4954 section 4).
        guard response == "=" || SMTPCommandParser.isValidBase64(response) else {
            return SMTPReply(501, "Invalid base64 data")
        }
        authenticated = true
        return SMTPReply(235, "Authentication successful")
    }

}
