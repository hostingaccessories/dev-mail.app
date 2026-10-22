import Foundation

/// A reply sent from the server to the client: a three-digit code and one or more lines of text.
struct SMTPReply: Sendable, Equatable {
    let code: Int
    let lines: [String]

    init(_ code: Int, _ lines: String...) {
        self.code = code
        self.lines = lines.isEmpty ? [""] : lines
    }

    init(_ code: Int, lines: [String]) {
        self.code = code
        self.lines = lines.isEmpty ? [""] : lines
    }

    /// The reply as sent on the wire. Every line but the last uses `code-text` (RFC 5321 section 4.2.1).
    var wireFormat: String {
        lines.enumerated()
            .map { index, line in
                let separator = index == lines.count - 1 ? " " : "-"
                return "\(code)\(separator)\(line)\r\n"
            }
            .joined()
    }
}
