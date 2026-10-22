/// Splits a multipart body into the byte ranges of its parts (RFC 2046 §5.1.1).
enum MultipartSplitter {
    private enum Delimiter {
        case part
        case close
    }

    private static let dash: UInt8 = 0x2D

    /// Ranges of each body part, excluding the preamble, epilogue, and the line break before each delimiter.
    /// A missing close delimiter ends the last part at the end of the body.
    static func split(_ bytes: [UInt8], body: Range<Int>, boundary: String) -> [Range<Int>] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [Range<Int>] = []
        var partStart: Int?
        var lineStart = body.lowerBound

        while lineStart < body.upperBound {
            let newline = bytes[lineStart..<body.upperBound].firstIndex(of: ASCII.lineFeed)
            let lineEnd = newline ?? body.upperBound
            let nextLineStart = newline.map { $0 + 1 } ?? body.upperBound

            if let kind = delimiterKind(bytes[lineStart..<lineEnd], delimiter: delimiter) {
                if let start = partStart {
                    parts.append(start..<contentEnd(bytes, before: lineStart, notBefore: start))
                }
                if kind == .close { return parts }
                partStart = nextLineStart
            }
            lineStart = nextLineStart
        }
        if let start = partStart {
            parts.append(start..<body.upperBound)
        }
        return parts
    }

    /// Guesses the boundary when Content-Type omits it: the first line that looks like a delimiter.
    static func sniffBoundary(_ bytes: [UInt8], body: Range<Int>) -> String? {
        var lineStart = body.lowerBound
        while lineStart < body.upperBound {
            let newline = bytes[lineStart..<body.upperBound].firstIndex(of: ASCII.lineFeed)
            let lineEnd = HeaderParser.lineContentEnd(bytes, start: lineStart, end: newline ?? body.upperBound)
            let line = bytes[lineStart..<lineEnd]
            if line.count > 2, line.starts(with: [dash, dash]) {
                let candidate = CharsetDecoder.decodeUnlabeled(line.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                return candidate.isEmpty ? nil : candidate
            }
            lineStart = newline.map { $0 + 1 } ?? body.upperBound
        }
        return nil
    }

    private static func delimiterKind(_ line: ArraySlice<UInt8>, delimiter: [UInt8]) -> Delimiter? {
        guard line.starts(with: delimiter) else { return nil }
        let rest = line.dropFirst(delimiter.count)
        if rest.starts(with: [dash, dash]) { return .close }
        // Anything other than transport padding means this is a longer boundary that merely shares a prefix.
        return rest.allSatisfy { ASCII.isWhitespace($0) || $0 == ASCII.carriageReturn } ? .part : nil
    }

    /// The CRLF (or LF) preceding a delimiter belongs to the delimiter, not to the part.
    private static func contentEnd(_ bytes: [UInt8], before lineStart: Int, notBefore start: Int) -> Int {
        var end = lineStart
        if end > start && bytes[end - 1] == ASCII.lineFeed { end -= 1 }
        if end > start && bytes[end - 1] == ASCII.carriageReturn { end -= 1 }
        return end
    }
}
