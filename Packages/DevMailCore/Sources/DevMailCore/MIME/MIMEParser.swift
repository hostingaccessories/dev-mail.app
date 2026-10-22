import Foundation

/// Parses raw RFC 5322 / MIME messages into a `ParsedMessage`.
public enum MIMEParser {
    /// Multipart nesting deeper than this is ignored; legitimate mail rarely exceeds 4 or 5 levels.
    static let maxDepth = 32
    /// Entities beyond this count are ignored, bounding work on pathological input.
    static let maxPartCount = 1_000

    /// Parses a message. Never throws: malformed input yields as much as could be recovered.
    public static func parse(_ data: Data) -> ParsedMessage {
        let bytes = [UInt8](data)
        let top = HeaderParser.parse(bytes, in: 0..<bytes.count)
        var collector = BodyPartCollector(bytes: bytes)
        collector.visit(headers: top.headers, body: top.bodyStart..<bytes.count, depth: 0, defaultType: "text/plain")

        let headers = top.headers
        func addresses(_ name: String) -> [EmailAddress] {
            headers.all(named: name).flatMap { AddressParser.parse($0.value) }
        }

        return ParsedMessage(
            rawSource: data,
            headers: headers.map { MessageHeader(name: $0.name, value: $0.decodedValue) },
            subject: headers.first(named: "Subject")?.decodedValue,
            from: addresses("From"),
            to: addresses("To"),
            cc: addresses("Cc"),
            bcc: addresses("Bcc"),
            replyTo: addresses("Reply-To"),
            date: headers.first(named: "Date").flatMap { MailDateParser.parse($0.value) },
            messageID: headers.first(named: "Message-ID").map { HeaderValues.normalizedIdentifier($0.value) }
                .flatMap { $0.isEmpty ? nil : $0 },
            htmlBody: collector.htmlBody,
            textBody: collector.textBody,
            attachments: collector.attachments,
            inlineParts: collector.inlineParts
        )
    }
}

/// Walks the MIME tree, choosing body parts and collecting attachments and inline parts.
struct BodyPartCollector {
    let bytes: [UInt8]
    private(set) var textBody: String?
    private(set) var htmlBody: String?
    private(set) var attachments: [MessagePart] = []
    private(set) var inlineParts: [MessagePart] = []
    private var entityCount = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func visit(headers: [RawHeader], body: Range<Int>, depth: Int, defaultType: String) {
        entityCount += 1
        guard entityCount <= MIMEParser.maxPartCount else { return }

        let contentType = headers.first(named: "Content-Type").map { HeaderValues.parameterized($0.value) }
        let mimeType = contentType.map(\.value).flatMap(validMIMEType) ?? defaultType
        let parameters = contentType?.parameters ?? [:]

        guard mimeType.hasPrefix("multipart/") else {
            visitLeaf(headers: headers, body: body, mimeType: mimeType, parameters: parameters)
            return
        }
        guard depth < MIMEParser.maxDepth else { return }

        let boundary =
            parameters["boundary"].flatMap { $0.isEmpty ? nil : $0 }
            ?? MultipartSplitter.sniffBoundary(bytes, body: body)
        let partRanges = boundary.map { MultipartSplitter.split(bytes, body: body, boundary: $0) } ?? []
        guard !partRanges.isEmpty else {
            // No usable structure: show the raw body rather than nothing.
            visitLeaf(headers: [], body: body, mimeType: "text/plain", parameters: [:])
            return
        }

        let childDefault = mimeType == "multipart/digest" ? "message/rfc822" : "text/plain"
        for range in partRanges {
            let child = HeaderParser.parse(bytes, in: range)
            visit(
                headers: child.headers,
                body: child.bodyStart..<range.upperBound,
                depth: depth + 1,
                defaultType: childDefault
            )
        }
    }

    private mutating func visitLeaf(
        headers: [RawHeader],
        body: Range<Int>,
        mimeType: String,
        parameters: [String: String]
    ) {
        let data = TransferDecoder.decode(
            bytes[body],
            encoding: headers.first(named: "Content-Transfer-Encoding")?.value
        )
        let disposition = headers.first(named: "Content-Disposition").map { HeaderValues.parameterized($0.value) }
        let isAttachment = disposition?.value == "attachment"
        let filename = disposition?.parameters["filename"] ?? parameters["name"]
        let contentID = headers.first(named: "Content-ID")
            .map { HeaderValues.normalizedIdentifier($0.value) }
            .flatMap { $0.isEmpty ? nil : $0 }

        if !isAttachment && filename == nil && contentID == nil && claimAsBody(data, mimeType, parameters["charset"]) {
            return
        }

        let part = MessagePart(filename: filename, mimeType: mimeType, contentID: contentID, data: data)
        if contentID != nil {
            inlineParts.append(part)
        }
        if contentID == nil || isAttachment {
            attachments.append(part)
        }
    }

    /// Uses the part as the text or HTML body if it is the first of its kind. Later ones become attachments.
    private mutating func claimAsBody(_ data: Data, _ mimeType: String, _ charset: String?) -> Bool {
        switch mimeType {
        case "text/plain" where textBody == nil:
            textBody = Self.normalizeLineEndings(CharsetDecoder.decode(data, charset: charset))
        case "text/html" where htmlBody == nil:
            htmlBody = Self.normalizeLineEndings(CharsetDecoder.decode(data, charset: charset))
        default:
            return false
        }
        return true
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Accepts `type/subtype` made of token characters; anything else falls back to the default type.
    private func validMIMEType(_ value: String) -> String? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) else {
            return nil
        }
        return value
    }
}
