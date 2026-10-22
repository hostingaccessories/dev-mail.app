import Foundation

/// The indexed fields of a stored message, enough to render the message list without reading its file.
public struct MessageSummary: Sendable, Identifiable, Hashable, Codable {
    public var id: UUID

    /// First `From` address, or the envelope sender when the header is missing.
    public var sender: EmailAddress?

    /// `To` and `Cc` display strings, or the envelope recipients when both headers are empty.
    public var recipients: [String]

    /// Envelope sender from `MAIL FROM`, or `nil` for the null reverse-path.
    public var envelopeSender: String?

    /// Envelope recipients from `RCPT TO`. Includes Bcc recipients that never appear in the headers.
    public var envelopeRecipients: [String]

    public var subject: String?

    /// The `Date` header, or `receivedAt` when it is missing or unparseable.
    public var date: Date

    /// When the server accepted the message, truncated to whole milliseconds.
    public var receivedAt: Date

    /// Size of the raw message in bytes.
    public var size: Int

    public var snippet: String
    public var hasAttachments: Bool
    public var isRead: Bool

    public init(
        id: UUID,
        sender: EmailAddress?,
        recipients: [String],
        envelopeSender: String?,
        envelopeRecipients: [String],
        subject: String?,
        date: Date,
        receivedAt: Date,
        size: Int,
        snippet: String,
        hasAttachments: Bool,
        isRead: Bool
    ) {
        self.id = id
        self.sender = sender
        self.recipients = recipients
        self.envelopeSender = envelopeSender
        self.envelopeRecipients = envelopeRecipients
        self.subject = subject
        self.date = date
        self.receivedAt = receivedAt
        self.size = size
        self.snippet = snippet
        self.hasAttachments = hasAttachments
        self.isRead = isRead
    }

    init(id: UUID, receivedAt: Date, data: Data, metadata: StoredMessageMetadata) {
        let parsed = MIMEParser.parse(data)
        let headerRecipients = (parsed.to + parsed.cc).map(\.displayString)
        self.init(
            id: id,
            sender: parsed.from.first ?? metadata.envelopeSender.map { EmailAddress(address: $0) },
            recipients: headerRecipients.isEmpty ? metadata.envelopeRecipients : headerRecipients,
            envelopeSender: metadata.envelopeSender,
            envelopeRecipients: metadata.envelopeRecipients,
            subject: parsed.subject,
            date: parsed.date ?? receivedAt,
            receivedAt: receivedAt,
            size: data.count,
            snippet: parsed.snippet,
            hasAttachments: !parsed.attachments.isEmpty,
            isRead: metadata.isRead
        )
    }

    /// Case- and diacritic-insensitive match against the subject, sender and recipients.
    func matches(_ query: String) -> Bool {
        var fields = recipients + envelopeRecipients
        if let subject { fields.append(subject) }
        if let sender { fields.append(sender.displayString) }
        if let envelopeSender { fields.append(envelopeSender) }
        return fields.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Envelope and read state kept in an extended attribute on each `.eml` file, so they survive an index rebuild
/// without altering the original message bytes.
struct StoredMessageMetadata: Codable, Equatable {
    var envelopeSender: String?
    var envelopeRecipients: [String]
    var isRead: Bool

    static let empty = Self(envelopeSender: nil, envelopeRecipients: [], isRead: false)
}
