import Foundation

/// Byte constants shared by the MIME parsing code.
enum ASCII {
    static let tab: UInt8 = 0x09
    static let lineFeed: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let equals: UInt8 = 0x3D
    static let underscore: UInt8 = 0x5F

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

/// Removes Content-Transfer-Encoding. Decoders are lenient: invalid input is skipped or kept literally rather than
/// rejected, because a partially readable body beats an error in a debugging tool.
enum TransferDecoder {
    static func decode(_ bytes: ArraySlice<UInt8>, encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            Data(decodeBase64(bytes))
        case "quoted-printable":
            Data(decodeQuotedPrintable(bytes))
        default:
            // 7bit, 8bit, binary, and anything unrecognised are passed through untouched.
            Data(bytes)
        }
    }

    static func decodeBase64(_ bytes: some Collection<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count / 4 * 3)
        var buffer: UInt32 = 0
        var bitCount = 0

        for byte in bytes {
            if byte == ASCII.equals {
                // Padding ends a chunk; resetting lets concatenated base64 blocks decode correctly.
                buffer = 0
                bitCount = 0
                continue
            }
            guard let value = base64Value(byte) else { continue }
            buffer = (buffer << 6) | UInt32(value)
            bitCount += 6
            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bitCount)))
            }
        }
        return output
    }

    /// Decodes quoted-printable. With `underscoreIsSpace` it decodes the RFC 2047 "Q" variant used in headers.
    static func decodeQuotedPrintable(_ bytes: some Collection<UInt8>, underscoreIsSpace: Bool = false) -> [UInt8] {
        let input = Array(bytes)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            let byte = input[index]
            if byte == ASCII.equals {
                if let next = softLineBreakEnd(in: input, after: index) {
                    index = next
                } else if index + 2 < input.count,
                    let high = ASCII.hexValue(input[index + 1]),
                    let low = ASCII.hexValue(input[index + 2])
                {
                    output.append(high << 4 | low)
                    index += 3
                } else {
                    output.append(byte)
                    index += 1
                }
            } else {
                output.append(underscoreIsSpace && byte == ASCII.underscore ? ASCII.space : byte)
                index += 1
            }
        }
        return output
    }

    /// If the `=` at `index` is a soft line break (optionally followed by trailing whitespace), returns the index
    /// just past the line break.
    private static func softLineBreakEnd(in input: [UInt8], after index: Int) -> Int? {
        var cursor = index + 1
        while cursor < input.count, ASCII.isWhitespace(input[cursor]) {
            cursor += 1
        }
        guard cursor < input.count else { return cursor }
        if input[cursor] == ASCII.lineFeed { return cursor + 1 }
        if input[cursor] == ASCII.carriageReturn {
            let afterReturn = cursor + 1
            return afterReturn < input.count && input[afterReturn] == ASCII.lineFeed ? afterReturn + 1 : afterReturn
        }
        return nil
    }

    private static func base64Value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x41...0x5A: byte - 0x41  // A-Z
        case 0x61...0x7A: byte - 0x61 + 26  // a-z
        case 0x30...0x39: byte - 0x30 + 52  // 0-9
        case 0x2B, 0x2D: 62  // + (and URL-safe -)
        case 0x2F, 0x5F: 63  // / (and URL-safe _)
        default: nil
        }
    }
}
