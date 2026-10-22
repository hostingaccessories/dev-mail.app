import Foundation

/// A decoded leaf MIME part that is not used as the message body: an attachment or an inline (`cid:`) resource.
public struct MessagePart: Sendable, Hashable {
    /// Filename as supplied by the sender, already decoded (RFC 2231 / RFC 2047). Not sanitised: never use it
    /// as a filesystem path without cleaning it first.
    public var filename: String?

    /// Lowercased `type/subtype`, e.g. `image/png`.
    public var mimeType: String

    /// Content-ID without angle brackets, used to resolve `cid:` URLs.
    public var contentID: String?

    /// Content after the transfer encoding (base64, quoted-printable) has been removed.
    public var data: Data

    public init(filename: String? = nil, mimeType: String, contentID: String? = nil, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.contentID = contentID
        self.data = data
    }

    /// Decoded size in bytes.
    public var size: Int { data.count }
}
