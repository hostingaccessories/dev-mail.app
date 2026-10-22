import Foundation

/// A header field with its value unfolded and RFC 2047 encoded words decoded.
public struct MessageHeader: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A message parsed into the pieces the UI displays. Produced by `MIMEParser.parse(_:)`.
public struct ParsedMessage: Sendable, Hashable {
    /// The unmodified message bytes, for "view source" and re-parsing.
    public var rawSource: Data

    /// Top-level headers in their original order.
    public var headers: [MessageHeader]

    public var subject: String?
    public var from: [EmailAddress]
    // swiftlint:disable:next identifier_name
    public var to: [EmailAddress]
    // swiftlint:disable:next identifier_name
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var date: Date?

    /// Message-ID without angle brackets.
    public var messageID: String?

    /// The first `text/html` body part, decoded to a string. `cid:` references are left untouched.
    public var htmlBody: String?

    /// The first `text/plain` body part, decoded to a string with LF line endings.
    public var textBody: String?

    /// Parts meant to be saved by the user: anything that is neither a body nor an inline `cid:` resource, plus
    /// `cid:` parts explicitly marked `Content-Disposition: attachment`.
    public var attachments: [MessagePart]

    /// Parts with a Content-ID, used to resolve `cid:` URLs in `htmlBody`.
    public var inlineParts: [MessagePart]

    public init(
        rawSource: Data = Data(),
        headers: [MessageHeader] = [],
        subject: String? = nil,
        from: [EmailAddress] = [],
        to: [EmailAddress] = [],  // swiftlint:disable:this identifier_name
        cc: [EmailAddress] = [],  // swiftlint:disable:this identifier_name
        bcc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        date: Date? = nil,
        messageID: String? = nil,
        htmlBody: String? = nil,
        textBody: String? = nil,
        attachments: [MessagePart] = [],
        inlineParts: [MessagePart] = []
    ) {
        self.rawSource = rawSource
        self.headers = headers
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.date = date
        self.messageID = messageID
        self.htmlBody = htmlBody
        self.textBody = textBody
        self.attachments = attachments
        self.inlineParts = inlineParts
    }

    /// Value of the first header with this name (case-insensitive).
    public func headerValue(named name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Finds the inline part for a Content-ID, with or without angle brackets. A `cid:` URL must be stripped of its
    /// scheme and percent-decoded first (RFC 2392).
    public func inlinePart(contentID: String) -> MessagePart? {
        let wanted = HeaderValues.normalizedIdentifier(contentID)
        return inlineParts.first { $0.contentID == wanted }
    }

    /// Up to ~200 characters of whitespace-collapsed text for list previews, taken from the plain-text body or,
    /// failing that, the HTML body with markup removed.
    public var snippet: String {
        let limit = 200
        if let textBody, !textBody.allSatisfy(\.isWhitespace) {
            return HTMLText.collapsingWhitespace(textBody, limit: limit)
        }
        if let htmlBody {
            return HTMLText.plainText(fromHTML: htmlBody, limit: limit)
        }
        return ""
    }
}
