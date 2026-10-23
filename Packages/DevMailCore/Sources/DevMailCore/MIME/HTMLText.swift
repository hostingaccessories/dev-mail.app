import Foundation

/// Cheap HTML-to-text conversion for previews. Not a renderer: it drops markup, skips non-visible blocks, decodes
/// common entities, and collapses whitespace.
enum HTMLText {
    /// Elements whose content is never visible text.
    private static let hiddenElements = ["head", "style", "script", "title"]

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "euro": "€", "zwnj": "", "zwj": "", "shy": "",
    ]

    /// Zero-width characters email templates use to pad preheaders.
    private static let invisibleScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{034F}", "\u{00AD}", "\u{FEFF}",
    ]

    static func plainText(fromHTML html: String, limit: Int) -> String {
        var output = TextAccumulator(limit: limit)
        var index = html.startIndex

        while index < html.endIndex, !output.isFull {
            let character = html[index]
            if character == "<" {
                index = indexAfterMarkup(in: html, at: index)
                output.append(" ")
            } else if character == "&", let (decoded, next) = entity(in: html, at: index) {
                output.append(decoded)
                index = next
            } else {
                output.append(String(character))
                index = html.index(after: index)
            }
        }
        return output.text
    }

    /// Elements that start a new line, and those that also leave a blank line around them.
    private static let lineBreakElements: Set<String> = ["br", "div", "tr", "li", "ul", "ol", "dt", "dd"]
    private static let paragraphElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "table", "blockquote", "hr", "pre",
        "section", "article", "header", "footer",
    ]

    /// Text for reading in a terminal: like `plainText(fromHTML:limit:)`, but block elements keep their line breaks,
    /// list items get a bullet, and runs of blank lines are reduced to one.
    static func readableText(fromHTML html: String) -> String {
        var marked = ""
        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            if character == "<" {
                marked += breakText(forTagAt: index, in: html)
                index = indexAfterMarkup(in: html, at: index)
            } else if character == "&", let (decoded, next) = entity(in: html, at: index) {
                // Decoded line breaks would be indistinguishable from block breaks, so they're spaces like any other.
                marked += decoded == "\n" ? " " : decoded
                index = next
            } else {
                marked.append(character.isNewline ? " " : character)
                index = html.index(after: index)
            }
        }

        var lines: [String] = []
        for line in marked.split(separator: "\n", omittingEmptySubsequences: false) {
            let collapsed = collapsingWhitespace(String(line), limit: .max)
            if collapsed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(collapsed)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The line breaks a tag at `start` stands for: none for inline elements.
    private static func breakText(forTagAt start: String.Index, in html: String) -> String {
        var name = html[html.index(after: start)...]
        let isClosing = name.first == "/"
        if isClosing { name = name.dropFirst() }
        let tagName = name.prefix { $0.isLetter || $0.isNumber }.lowercased()

        if paragraphElements.contains(tagName) { return "\n\n" }
        if tagName == "li" { return isClosing ? "" : "\n• " }
        if lineBreakElements.contains(tagName) { return "\n" }
        // Table cells on one row stay apart.
        if tagName == "td" || tagName == "th" { return " " }
        return ""
    }

    static func collapsingWhitespace(_ text: String, limit: Int) -> String {
        var output = TextAccumulator(limit: limit)
        for character in text {
            output.append(String(character))
            if output.isFull { break }
        }
        return output.text
    }

    /// Skips a tag, comment, or whole hidden element starting at `<`.
    private static func indexAfterMarkup(in html: String, at start: String.Index) -> String.Index {
        let rest = html[start...]
        if rest.hasPrefix("<!--") {
            return rest.range(of: "-->")?.upperBound ?? html.endIndex
        }
        let tagEnd = rest.firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
        let tagName = rest.dropFirst().prefix { $0.isLetter || $0.isNumber }.lowercased()
        guard hiddenElements.contains(tagName), !rest[..<tagEnd].hasSuffix("/>") else { return tagEnd }

        let closing = html[tagEnd...].range(of: "</\(tagName)", options: .caseInsensitive)
        guard let closing else { return html.endIndex }
        return html[closing.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
    }

    /// Decodes `&name;`, `&#123;`, or `&#x1F600;` at `start`, returning the text and the index after it.
    private static func entity(in html: String, at start: String.Index) -> (String, String.Index)? {
        let candidate = html[html.index(after: start)...].prefix(12)
        guard let semicolon = candidate.firstIndex(of: ";") else { return nil }
        let name = String(candidate[..<semicolon])
        let next = html.index(after: semicolon)

        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let isHex = digits.first == "x" || digits.first == "X"
            let value = isHex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return (String(Character(scalar)), next)
        }
        return namedEntities[name.lowercased()].map { ($0, next) }
    }

    /// Builds collapsed, trimmed text, stopping once `limit` characters have been collected.
    private struct TextAccumulator {
        let limit: Int
        private(set) var text = ""
        private var scalarCount = 0
        private var pendingSpace = false

        init(limit: Int) {
            self.limit = limit
        }

        var isFull: Bool { scalarCount >= limit }

        mutating func append(_ string: String) {
            for scalar in string.unicodeScalars where !HTMLText.invisibleScalars.contains(scalar) {
                if scalar.properties.isWhitespace {
                    pendingSpace = !text.isEmpty
                    continue
                }
                guard scalarCount < limit else { return }
                if pendingSpace {
                    text.unicodeScalars.append(" ")
                    scalarCount += 1
                    pendingSpace = false
                }
                text.unicodeScalars.append(scalar)
                scalarCount += 1
            }
        }
    }
}
