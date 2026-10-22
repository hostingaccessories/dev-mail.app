import Foundation

/// A message accepted by the SMTP server, as received from the client.
public struct ReceivedMessage: Sendable, Equatable, Identifiable {
    public let id: UUID

    /// Envelope sender from `MAIL FROM`, or `nil` for the null reverse-path (`MAIL FROM:<>`).
    public let envelopeSender: String?

    /// Envelope recipients from `RCPT TO`, in the order given.
    public let recipients: [String]

    /// Raw RFC 5322 message bytes after dot-unstuffing, with CRLF line endings.
    public let data: Data

    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        envelopeSender: String?,
        recipients: [String],
        data: Data,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.envelopeSender = envelopeSender
        self.recipients = recipients
        self.data = data
        self.receivedAt = receivedAt
    }
}
