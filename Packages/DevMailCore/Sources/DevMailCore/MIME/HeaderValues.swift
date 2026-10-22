import Foundation

/// A structured header value such as `text/plain; charset=utf-8` or `attachment; filename="a.pdf"`.
struct ParameterizedValue {
    /// The lowercased leading token, e.g. `text/plain` or `attachment`.
    var value: String
    /// Parameters keyed by lowercased name, with RFC 2231 continuations joined and all encodings decoded.
    var parameters: [String: String]
}

/// Parsing helpers for structured header values.
enum HeaderValues {
    private static let maxParameterCount = 64
    private static let maxContinuationIndex = 999

    /// Strips whitespace and surrounding angle brackets from a Message-ID or Content-ID.
    static func normalizedIdentifier(_ value: String) -> String {
        var identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if identifier.hasPrefix("<") { identifier.removeFirst() }
        if let closing = identifier.firstIndex(of: ">") { identifier = String(identifier[..<closing]) }
        return identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parameterized(_ raw: String) -> ParameterizedValue {
        let pieces = splitOutsideQuotes(raw, separator: ";")
        let value = (pieces.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var pairs: [(name: String, value: String)] = []
        for piece in pieces.dropFirst().prefix(maxParameterCount) {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            pairs.append((name, unquote(rawValue)))
        }
        return ParameterizedValue(value: value, parameters: resolveParameters(pairs))
    }

    /// Splits on `separator` except inside double-quoted strings.
    static func splitOutsideQuotes(_ raw: String, separator: Character) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for character in raw {
            if escaped {
                escaped = false
            } else if inQuotes && character == "\\" {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == separator && !inQuotes {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        pieces.append(current)
        return pieces
    }

    /// Removes surrounding double quotes and backslash escapes. Unterminated quotes are tolerated.
    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\"") else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: - RFC 2231

    private struct Section {
        var index: Int
        var value: String
        var isExtended: Bool
    }

    /// Joins RFC 2231 continuations (`name*0*=`, `name*1=`) and decodes extended values (`name*=utf-8''a%20b`).
    /// Extended forms win over plain ones; plain values may still carry RFC 2047 encoded words.
    private static func resolveParameters(_ pairs: [(name: String, value: String)]) -> [String: String] {
        var plain: [String: String] = [:]
        var sections: [String: [Section]] = [:]

        for pair in pairs {
            let nameParts = pair.name.split(separator: "*", omittingEmptySubsequences: false)
            guard nameParts.count > 1, let base = nameParts.first.map(String.init) else {
                plain[pair.name] = plain[pair.name] ?? EncodedWordDecoder.decode(pair.value)
                continue
            }
            let isExtended = nameParts.last?.isEmpty == true
            let index = nameParts.count == 2 && isExtended ? 0 : Int(nameParts[1]) ?? -1
            guard (0...maxContinuationIndex).contains(index) else { continue }
            sections[base, default: []].append(Section(index: index, value: pair.value, isExtended: isExtended))
        }

        var resolved = plain
        for (base, baseSections) in sections {
            resolved[base] = joinSections(baseSections)
        }
        return resolved
    }

    private static func joinSections(_ sections: [Section]) -> String {
        let ordered = sections.sorted { $0.index < $1.index }
        var charset: String?
        var bytes: [UInt8] = []

        for (position, section) in ordered.enumerated() {
            guard section.isExtended else {
                bytes += Array(section.value.utf8)
                continue
            }
            var encoded = Substring(section.value)
            if position == 0 {
                // First extended section is `charset'language'value`.
                let parts = section.value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    charset = parts[0].isEmpty ? nil : String(parts[0])
                    encoded = parts[2]
                }
            }
            bytes += percentDecode(encoded)
        }
        return CharsetDecoder.decode(bytes, charset: charset)
    }

    private static func percentDecode(_ value: Substring) -> [UInt8] {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < input.count {
            if input[index] == 0x25, index + 2 < input.count,  // %
                let high = ASCII.hexValue(input[index + 1]), let low = ASCII.hexValue(input[index + 2])
            {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(input[index])
                index += 1
            }
        }
        return output
    }
}
