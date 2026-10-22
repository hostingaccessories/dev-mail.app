/// Decodes RFC 2047 encoded words (`=?charset?B|Q?text?=`) in header text.
enum EncodedWordDecoder {
    private enum Segment {
        case text([UInt8])
        case encoded(charset: String, bytes: [UInt8])
    }

    private static let questionMark: UInt8 = 0x3F
    private static let maxCharsetLength = 64
    private static let maxEncodedTextLength = 4_096

    static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let segments = mergeAdjacentWords(split(Array(value.utf8)))

        var result = ""
        for segment in segments {
            switch segment {
            case .text(let bytes):
                result += CharsetDecoder.decodeUnlabeled(bytes)
            case .encoded(let charset, let bytes):
                result += CharsetDecoder.decode(bytes, charset: charset)
            }
        }
        return result
    }

    private static func split(_ input: [UInt8]) -> [Segment] {
        var segments: [Segment] = []
        var pendingText: [UInt8] = []
        var index = 0

        while index < input.count {
            if input[index] == ASCII.equals, let (word, next) = encodedWord(in: input, at: index) {
                if !pendingText.isEmpty {
                    segments.append(.text(pendingText))
                    pendingText = []
                }
                segments.append(word)
                index = next
            } else {
                pendingText.append(input[index])
                index += 1
            }
        }
        if !pendingText.isEmpty {
            segments.append(.text(pendingText))
        }
        return segments
    }

    /// Drops whitespace between adjacent encoded words (RFC 2047 §6.2) and joins their bytes when the charset matches,
    /// so multi-byte characters split across words decode correctly.
    private static func mergeAdjacentWords(_ segments: [Segment]) -> [Segment] {
        var merged: [Segment] = []
        for (offset, segment) in segments.enumerated() {
            if case .text(let bytes) = segment, bytes.allSatisfy(ASCII.isWhitespace),
                offset > 0, offset + 1 < segments.count,
                case .encoded = segments[offset - 1], case .encoded = segments[offset + 1]
            {
                continue
            }
            if case .encoded(let charset, let bytes) = segment,
                case .encoded(let previousCharset, let previousBytes)? = merged.last,
                previousCharset.caseInsensitiveCompare(charset) == .orderedSame
            {
                merged[merged.count - 1] = .encoded(charset: charset, bytes: previousBytes + bytes)
                continue
            }
            merged.append(segment)
        }
        return merged
    }

    /// Parses an encoded word starting at `start` (which points at `=`). Returns the decoded word and the index after it.
    private static func encodedWord(in input: [UInt8], at start: Int) -> (Segment, Int)? {
        guard start + 1 < input.count, input[start + 1] == questionMark else { return nil }

        let charsetStart = start + 2
        guard let charsetEnd = firstIndex(of: questionMark, in: input, from: charsetStart, limit: maxCharsetLength),
            charsetEnd > charsetStart, charsetEnd + 2 < input.count, input[charsetEnd + 2] == questionMark
        else { return nil }

        let textStart = charsetEnd + 3
        guard let textEnd = firstIndex(of: questionMark, in: input, from: textStart, limit: maxEncodedTextLength),
            textEnd + 1 < input.count, input[textEnd + 1] == ASCII.equals
        else { return nil }

        let text = input[textStart..<textEnd]
        let bytes: [UInt8]
        switch input[charsetEnd + 1] {
        case 0x42, 0x62:  // B, b
            bytes = TransferDecoder.decodeBase64(text)
        case 0x51, 0x71:  // Q, q
            bytes = TransferDecoder.decodeQuotedPrintable(text, underscoreIsSpace: true)
        default:
            return nil
        }

        // RFC 2231 allows a language suffix: `=?utf-8*en?Q?...?=`.
        let label = CharsetDecoder.decodeUnlabeled(input[charsetStart..<charsetEnd])
        let charset = label.split(separator: "*", maxSplits: 1).first.map(String.init) ?? label
        return (.encoded(charset: charset, bytes: bytes), textEnd + 2)
    }

    private static func firstIndex(of target: UInt8, in input: [UInt8], from start: Int, limit: Int) -> Int? {
        let end = min(input.count, start + limit)
        guard start < end else { return nil }
        return input[start..<end].firstIndex { $0 == target || $0 == ASCII.lineFeed || $0 == ASCII.carriageReturn }
            .flatMap { input[$0] == target ? $0 : nil }
    }
}
