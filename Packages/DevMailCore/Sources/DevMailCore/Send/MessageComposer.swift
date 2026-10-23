import Foundation
import UniformTypeIdentifiers

/// A message to send, built from command-line options and encoded as RFC 5322 / MIME by `MessageComposer`.
public struct OutgoingMessage: Sendable, Equatable {
    public var from: EmailAddress
    // swiftlint:disable:next identifier_name
    public var to: [EmailAddress]
    // swiftlint:disable:next identifier_name
    public var cc: [EmailAddress]

    /// Recipients that only the envelope carries; they never appear in the headers.
    public var bcc: [EmailAddress]

    public var subject: String?
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [OutgoingAttachment]

    /// Additional headers, such as `X-Mailer` or `Reply-To`, in order.
    public var extraHeaders: [MessageHeader]

    public var date: Date
    public var messageID: String

    public init(
        from: EmailAddress,
        to: [EmailAddress] = [],  // swiftlint:disable:this identifier_name
        cc: [EmailAddress] = [],  // swiftlint:disable:this identifier_name
        bcc: [EmailAddress] = [],
        subject: String? = nil,
        textBody: String? = nil,
        htmlBody: String? = nil,
        attachments: [OutgoingAttachment] = [],
        extraHeaders: [MessageHeader] = [],
        date: Date = Date(),
        messageID: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.extraHeaders = extraHeaders
        self.date = date
        let domain = from.address.split(separator: "@").last.map(String.init) ?? "localhost"
        self.messageID = messageID ?? "\(UUID().uuidString.lowercased())@\(domain)"
    }

    /// Every address the message is delivered to: To, Cc and Bcc.
    public var envelopeRecipients: [String] {
        (to + cc + bcc).map(\.address)
    }
}

public struct OutgoingAttachment: Sendable, Equatable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    /// Reads a file, taking its MIME type from the extension.
    public init(contentsOf url: URL) throws {
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        self.init(
            filename: url.lastPathComponent,
            mimeType: type ?? "application/octet-stream",
            data: try Data(contentsOf: url)
        )
    }
}

public enum MessageComposerError: Error, Equatable, LocalizedError {
    case invalidAddress(String)
    case invalidHeaderName(String)
    case invalidHeaderValue(name: String)
    case reservedHeader(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            "\"\(address)\" is not a valid email address."
        case .invalidHeaderName(let name):
            "\"\(name)\" is not a valid header name."
        case .invalidHeaderValue(let name):
            "The \(name) header can't contain line breaks."
        case .reservedHeader(let name):
            "The \(name) header is set by Dev Mail; use the matching option instead."
        }
    }
}

/// Encodes an `OutgoingMessage` as the bytes of an RFC 5322 message with CRLF line endings.
///
/// Text parts are UTF-8 in quoted-printable, attachments are base64, and non-ASCII header text uses RFC 2047 encoded
/// words, so the output is 7-bit clean and lines stay within 78 characters.
public enum MessageComposer {
    /// Headers this composer writes itself. `Bcc` is left out on purpose: Bcc recipients only go in the envelope.
    static let reservedHeaders: Set<String> = [
        "from", "to", "cc", "bcc", "subject", "date", "message-id", "mime-version",
        "content-type", "content-transfer-encoding", "content-disposition",
    ]

    public static func compose(_ message: OutgoingMessage) throws(MessageComposerError) -> Data {
        for address in [message.from] + message.to + message.cc + message.bcc {
            try validate(address)
        }
        for header in message.extraHeaders {
            try validate(header)
        }

        var lines: [String] = []
        lines.append("From: " + encode(message.from))
        if !message.to.isEmpty { lines.append(addressHeader("To", message.to)) }
        if !message.cc.isEmpty { lines.append(addressHeader("Cc", message.cc)) }
        if let subject = message.subject { lines.append("Subject: " + encodeText(subject, header: "Subject")) }
        lines.append("Date: " + rfc5322Date(message.date))
        lines.append("Message-ID: <\(message.messageID)>")
        for header in message.extraHeaders {
            lines.append("\(header.name): " + encodeText(header.value, header: header.name))
        }
        lines.append("MIME-Version: 1.0")
        lines.append(contentsOf: body(of: message))

        // A body that ends with a line break already ends the message with CRLF.
        var text = lines.joined(separator: "\r\n")
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        return Data(text.utf8)
    }

    // MARK: - Structure

    /// The body's headers and content: a single text part, `multipart/alternative` for text and HTML, wrapped in
    /// `multipart/mixed` when there are attachments.
    private static func body(of message: OutgoingMessage) -> [String] {
        var textParts: [[String]] = []
        if let text = message.textBody { textParts.append(textPart(text, subtype: "plain")) }
        if let html = message.htmlBody { textParts.append(textPart(html, subtype: "html")) }
        if textParts.isEmpty { textParts.append(textPart("", subtype: "plain")) }

        let content = textParts.count == 1 ? textParts[0] : multipart("alternative", textParts)
        guard !message.attachments.isEmpty else { return content }
        return multipart("mixed", [content] + message.attachments.map(attachmentPart))
    }

    /// A part's headers, a blank line and its content, as lines.
    private static func textPart(_ text: String, subtype: String) -> [String] {
        [
            "Content-Type: text/\(subtype); charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            quotedPrintable(text),
        ]
    }

    private static func attachmentPart(_ attachment: OutgoingAttachment) -> [String] {
        [
            "Content-Type: \(attachment.mimeType)",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; " + filenameParameter(attachment.filename),
            "",
            attachment.data.base64EncodedString(options: [
                .lineLength76Characters, .endLineWithCarriageReturn,
                .endLineWithLineFeed,
            ]),
        ]
    }

    private static func multipart(_ subtype: String, _ parts: [[String]]) -> [String] {
        // "=_" can't occur in quoted-printable or base64 content, so the boundary never collides with it.
        let boundary = "=_DevMail_\(UUID().uuidString)"
        var lines = ["Content-Type: multipart/\(subtype); boundary=\"\(boundary)\"", ""]
        for part in parts {
            lines.append("--\(boundary)")
            lines.append(contentsOf: part)
        }
        lines.append("--\(boundary)--")
        return lines
    }

    // MARK: - Headers

    private static func addressHeader(_ name: String, _ addresses: [EmailAddress]) -> String {
        "\(name): " + addresses.map(encode).joined(separator: ",\r\n ")
    }

    /// `address`, or `name <address>` with the name quoted or encoded as needed.
    static func encode(_ address: EmailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.address }
        let phrase: String
        if !name.allSatisfy(\.isASCII) {
            phrase = encodedWords(name)
        } else if name.allSatisfy({ $0.isLetter || $0.isNumber || " !#$%&'*+-/=?^_`{|}~".contains($0) }) {
            phrase = name
        } else {
            phrase =
                "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                + "\""
        }
        return "\(phrase) <\(address.address)>"
    }

    /// The text as is when it is printable ASCII, otherwise as encoded words that fit after `header`'s name.
    private static func encodeText(_ text: String, header: String) -> String {
        isPrintableASCII(text) ? text : encodedWords(text, firstLineUsed: header.count + 2)
    }

    /// RFC 2047 `=?utf-8?B?...?=` words folded onto continuation lines of at most 78 characters, the first of which
    /// already holds `firstLineUsed` characters. Words never split a character's UTF-8 bytes.
    private static func encodedWords(_ text: String, firstLineUsed: Int = 0) -> String {
        let prefix = "=?utf-8?B?"
        let suffix = "?="
        // Bytes whose base64 fits in `width` characters of a word, and at least one character's worth.
        func maxBytes(width: Int) -> Int {
            max((width - prefix.count - suffix.count) / 4 * 3, 4)
        }
        var words: [String] = []
        var chunk = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            // Continuation lines start with a space.
            let limit = words.isEmpty ? maxBytes(width: 78 - firstLineUsed) : maxBytes(width: 77)
            if chunk.count + bytes.count > limit, !chunk.isEmpty {
                words.append(prefix + chunk.base64EncodedString() + suffix)
                chunk = Data()
            }
            chunk.append(bytes)
        }
        words.append(prefix + chunk.base64EncodedString() + suffix)
        return words.joined(separator: "\r\n ")
    }

    /// `filename="name"` for ASCII names, or the RFC 2231 `filename*=utf-8''...` form for others.
    private static func filenameParameter(_ filename: String) -> String {
        if isPrintableASCII(filename) {
            let escaped = filename.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "filename=\"\(escaped)\""
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~"
        )
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
        return "filename*=utf-8''\(encoded)"
    }

    private static func isPrintableASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    private static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: - Validation

    /// Accepts a plain ASCII `local@domain` with nothing that could break out of the header or envelope.
    private static func validate(_ address: EmailAddress) throws(MessageComposerError) {
        let text = address.address
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        let forbidden = Set("<>(),;:\"[]\\".unicodeScalars)
        let isValid =
            parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && text.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && !forbidden.contains($0) }
        guard isValid else { throw .invalidAddress(text) }
        if let name = address.name, name.contains(where: \.isNewline) { throw .invalidAddress(text) }
    }

    private static func validate(_ header: MessageHeader) throws(MessageComposerError) {
        let nameIsValid =
            !header.name.isEmpty
            && header.name.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && $0 != ":" }
        guard nameIsValid else { throw .invalidHeaderName(header.name) }
        guard !reservedHeaders.contains(header.name.lowercased()) else { throw .reservedHeader(header.name) }
        guard !header.value.contains(where: \.isNewline) else { throw .invalidHeaderValue(name: header.name) }
    }

    // MARK: - Quoted-printable

    /// UTF-8 quoted-printable with CRLF line breaks and soft breaks keeping lines within 76 characters.
    static func quotedPrintable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { encodeLine(Array($0.utf8)) }
            .joined(separator: "\r\n")
    }

    private static func encodeLine(_ bytes: [UInt8]) -> String {
        var lines: [String] = []
        var line = ""
        for (index, byte) in bytes.enumerated() {
            let isLast = index == bytes.count - 1
            // Trailing whitespace is encoded, or transports may strip it.
            let isLiteral =
                (byte >= 33 && byte <= 126 && byte != UInt8(ascii: "=")) || ((byte == 32 || byte == 9) && !isLast)
            let token = isLiteral ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
            // Leave room for the "=" of a soft line break.
            if line.count + token.count > 75 {
                lines.append(line + "=")
                line = ""
            }
            line += token
        }
        lines.append(line)
        return lines.joined(separator: "\r\n")
    }
}
