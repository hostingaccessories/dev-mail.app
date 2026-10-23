import DevMailCore
import Foundation

/// Renders messages as terminal text.
struct MessageFormatting {
    var style: TerminalStyle
    var now: Date
    var timeZone: TimeZone = .current
    var locale: Locale = .current

    /// Sender and recipient columns are cut to this many characters so the subject stays on screen.
    static let maxAddressWidth = 28

    // MARK: - List

    /// A table of messages, newest first as given, with unread rows in bold.
    func table(_ summaries: [MessageSummary]) -> String {
        guard !summaries.isEmpty else { return "No messages." }

        let header = ["ID", "RECEIVED", "FROM", "TO", "SUBJECT"]
        let rows = summaries.map { summary in
            [
                MessageIDMatcher.shortID(summary.id),
                listDate(summary.receivedAt),
                Self.truncated(summary.sender?.displayString ?? "", to: Self.maxAddressWidth),
                Self.truncated(summary.recipients.joined(separator: ", "), to: Self.maxAddressWidth),
                (summary.subject ?? "(no subject)") + (summary.hasAttachments ? " 📎" : ""),
            ]
        }

        // The last column isn't padded, so long subjects don't push trailing spaces onto every line.
        let widths = (0..<header.count - 1).map { column in
            ([header] + rows).map { $0[column].count }.max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            zip(cells, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
                + "  " + (cells.last ?? "")
        }

        var lines = [style.dim(line(header))]
        for (summary, row) in zip(summaries, rows) {
            lines.append(summary.isRead ? line(row) : style.bold(line(row)))
        }
        return lines.joined(separator: "\n")
    }

    /// The time for today's messages, the day and time this year, and the date before that.
    func listDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let template: String
        if calendar.isDate(date, inSameDayAs: now) {
            template = "jjmm"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            template = "MMMdjjmm"
        } else {
            template = "yMMMd"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    // MARK: - Message

    /// The headers a mail client shows, the readable body and a list of attachments.
    func message(_ summary: MessageSummary, parsed: ParsedMessage) -> String {
        var fields: [(String, String)] = []
        func add(_ label: String, _ addresses: [EmailAddress]) {
            if !addresses.isEmpty { fields.append((label, addresses.map(\.displayString).joined(separator: ", "))) }
        }
        add("From", parsed.from)
        add("To", parsed.to)
        add("Cc", parsed.cc)
        add("Reply-To", parsed.replyTo)
        let blindCopies = Self.blindCopies(summary: summary, parsed: parsed)
        if !blindCopies.isEmpty { fields.append(("Bcc", blindCopies.joined(separator: ", "))) }
        fields.append(("Subject", parsed.subject ?? "(no subject)"))
        fields.append(("Date", fullDate(parsed.date ?? summary.date)))
        fields.append(("ID", summary.id.uuidString.lowercased()))

        let labelWidth = (fields.map(\.0.count).max() ?? 0) + 1
        var lines = fields.map { label, value in
            style.bold((label + ":").padding(toLength: labelWidth, withPad: " ", startingAt: 0)) + " " + value
        }
        lines.append("")
        lines.append(parsed.readableBody?.trimmingCharacters(in: .newlines) ?? style.dim("(no body)"))

        if !parsed.attachments.isEmpty {
            lines.append("")
            lines.append(style.bold("Attachments:"))
            for attachment in parsed.attachments {
                let name = attachment.filename ?? "(unnamed)"
                let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)
                lines.append("  \(name) " + style.dim("(\(attachment.mimeType), \(size))"))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Every header, unfolded and decoded, as `Name: value` lines.
    func headers(_ parsed: ParsedMessage) -> String {
        parsed.headers.map { style.bold($0.name + ":") + " " + $0.value }.joined(separator: "\n")
    }

    func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    // MARK: - Helpers

    /// Envelope recipients that appear in no To or Cc header: the Bcc recipients, which only the envelope records.
    static func blindCopies(summary: MessageSummary, parsed: ParsedMessage) -> [String] {
        let visible = Set((parsed.to + parsed.cc).map { $0.address.lowercased() })
        return summary.envelopeRecipients.filter { !visible.contains($0.lowercased()) }
    }

    static func truncated(_ text: String, to width: Int) -> String {
        text.count <= width ? text : String(text.prefix(width - 1)) + "…"
    }
}

/// The `--json` form of `mail show`.
struct MessageJSON: Encodable {
    struct Header: Encodable {
        var name: String
        var value: String
    }

    struct Attachment: Encodable {
        var filename: String?
        var mimeType: String
        var contentID: String?
        var size: Int
    }

    var summary: MessageSummary
    var headers: [Header]
    var textBody: String?
    var htmlBody: String?
    var attachments: [Attachment]

    init(summary: MessageSummary, parsed: ParsedMessage) {
        self.summary = summary
        headers = parsed.headers.map { Header(name: $0.name, value: $0.value) }
        textBody = parsed.textBody
        htmlBody = parsed.htmlBody
        attachments = parsed.attachments.map {
            Attachment(filename: $0.filename, mimeType: $0.mimeType, contentID: $0.contentID, size: $0.size)
        }
    }
}
