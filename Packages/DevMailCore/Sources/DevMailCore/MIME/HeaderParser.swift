import Foundation

/// A header as it appears on the wire after unfolding, before RFC 2047 decoding. Structured headers (addresses,
/// parameters) must be tokenised before encoded words are decoded, so the raw form is kept for them.
struct RawHeader: Sendable {
    let name: String
    let value: String

    var decodedValue: String {
        EncodedWordDecoder.decode(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension [RawHeader] {
    func first(named name: String) -> RawHeader? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func all(named name: String) -> [RawHeader] {
        filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Splits an entity into its header fields and the start of its body. Accepts CRLF and bare LF line endings.
enum HeaderParser {
    struct Result {
        var headers: [RawHeader]
        var bodyStart: Int
    }

    // Caps keep a hostile or broken message from ballooning memory; real mail stays far below them.
    static let maxHeaderCount = 1_000
    static let maxValueLength = 64 * 1024
    private static let maxNameLength = 256
    private static let colon: UInt8 = 0x3A

    static func parse(_ bytes: [UInt8], in range: Range<Int>) -> Result {
        var headers: [RawHeader] = []
        var pending: (name: String, value: [UInt8])?
        var lineStart = range.lowerBound

        func flushPending() {
            if let current = pending, headers.count < maxHeaderCount {
                headers.append(
                    RawHeader(name: current.name, value: CharsetDecoder.decodeUnlabeled(current.value))
                )
            }
            pending = nil
        }

        while lineStart < range.upperBound {
            let newline = bytes[lineStart..<range.upperBound].firstIndex(of: ASCII.lineFeed)
            let nextLineStart = newline.map { $0 + 1 } ?? range.upperBound
            let line = bytes[lineStart..<lineContentEnd(bytes, start: lineStart, end: newline ?? range.upperBound)]

            if line.isEmpty {
                flushPending()
                return Result(headers: headers, bodyStart: nextLineStart)
            }
            if let first = line.first, ASCII.isWhitespace(first) {
                // Unfolding (RFC 5322 §2.2.3): drop the line break, keep the leading whitespace.
                if let length = pending?.value.count, length + line.count <= maxValueLength {
                    pending?.value.append(contentsOf: line)
                }
            } else if let nameEnd = fieldNameEnd(line) {
                flushPending()
                let name = CharsetDecoder.decodeUnlabeled(line[line.startIndex..<nameEnd])
                    .trimmingCharacters(in: .whitespaces)
                pending = (name, Array(line[(nameEnd + 1)...].prefix(maxValueLength)))
            } else if lineStart == range.lowerBound, line.starts(with: Array("From ".utf8)) {
                // mbox separator line; not a header.
            } else {
                // Not a header: assume the blank separator line is missing and the body starts here.
                flushPending()
                return Result(headers: headers, bodyStart: lineStart)
            }
            lineStart = nextLineStart
        }
        flushPending()
        return Result(headers: headers, bodyStart: range.upperBound)
    }

    /// End of the line's content, excluding a trailing CR.
    static func lineContentEnd(_ bytes: [UInt8], start: Int, end: Int) -> Int {
        end > start && bytes[end - 1] == ASCII.carriageReturn ? end - 1 : end
    }

    /// Index of the colon ending a valid field name (printable ASCII, optionally followed by whitespace).
    private static func fieldNameEnd(_ line: ArraySlice<UInt8>) -> Int? {
        guard let colonIndex = line.prefix(maxNameLength + 8).firstIndex(of: colon), colonIndex > line.startIndex
        else { return nil }
        let name = line[line.startIndex..<colonIndex]
        let trimmed = name.reversed().drop(while: ASCII.isWhitespace)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else { return nil }
        return trimmed.allSatisfy { (0x21...0x7E).contains($0) } ? colonIndex : nil
    }
}
