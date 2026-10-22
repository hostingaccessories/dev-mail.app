import Foundation

/// Parses RFC 5322 address lists, including groups, quoted display names, comments, and encoded words.
enum AddressParser {
    static func parse(_ raw: String) -> [EmailAddress] {
        splitMailboxes(raw).compactMap(parseMailbox)
    }

    /// Splits at top-level commas, and treats `group-name:` ... `;` as a list of its members.
    private static func splitMailboxes(_ raw: String) -> [String] {
        var scanner = StructuredTextScanner()
        var mailboxes: [String] = []
        var current = ""

        for character in raw {
            guard scanner.isAtTopLevel(after: character) else {
                current.append(character)
                continue
            }
            switch character {
            case "," where !scanner.inAngleBrackets, ";" where !scanner.inAngleBrackets:
                mailboxes.append(current)
                current = ""
            case ":" where !scanner.inAngleBrackets:
                // Group display name: discard it, its members follow.
                current = ""
            default:
                current.append(character)
            }
        }
        mailboxes.append(current)
        return mailboxes
    }

    private static func parseMailbox(_ raw: String) -> EmailAddress? {
        let (text, comments) = removeComments(raw)

        var phrase = text
        var address = text
        if let open = topLevelAngleBracket(in: text) {
            phrase = String(text[..<open])
            let afterOpen = text[text.index(after: open)...]
            address = String(afterOpen.prefix { $0 != ">" })
            // Obsolete source routes: `<@relay.example:user@example.com>`.
            if let colon = address.lastIndex(of: ":") {
                address = String(address[address.index(after: colon)...])
            }
        } else {
            phrase = comments.joined(separator: " ")
        }

        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }

        let name = displayName(fromPhrase: phrase)
        let isRedundant = name.map { $0.caseInsensitiveCompare(address) == .orderedSame } ?? false
        return EmailAddress(name: isRedundant ? nil : name, address: address)
    }

    private static func displayName(fromPhrase phrase: String) -> String? {
        var name = unquoteAll(phrase)
        name = EncodedWordDecoder.decode(name)
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Some clients wrap the name in single quotes: 'Jane Doe' <jane@example.com>.
        if name.count >= 2, name.hasPrefix("'"), name.hasSuffix("'") {
            name = String(name.dropFirst().dropLast())
        }
        return name.isEmpty ? nil : name
    }

    /// Removes double-quote delimiters and backslash escapes from every quoted string in the phrase.
    private static func unquoteAll(_ phrase: String) -> String {
        var result = ""
        var inQuotes = false
        var escaped = false
        for character in phrase {
            if escaped {
                result.append(character)
                escaped = false
            } else if inQuotes && character == "\\" {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Splits out `(comments)`, returning the remaining text and the comment contents.
    private static func removeComments(_ raw: String) -> (text: String, comments: [String]) {
        var scanner = StructuredTextScanner()
        var text = ""
        var comments: [String] = []
        var comment = ""

        for character in raw {
            let wasInComment = scanner.commentDepth > 0
            _ = scanner.isAtTopLevel(after: character)
            let isInComment = scanner.commentDepth > 0
            if wasInComment || isInComment {
                if wasInComment && isInComment { comment.append(character) }
                if wasInComment && !isInComment {
                    comments.append(comment)
                    comment = ""
                }
            } else {
                text.append(character)
            }
        }
        return (text, comments)
    }

    private static func topLevelAngleBracket(in text: String) -> String.Index? {
        var scanner = StructuredTextScanner()
        for index in text.indices {
            let isTopLevel = scanner.isAtTopLevel(after: text[index])
            if isTopLevel && text[index] == "<" {
                return index
            }
        }
        return nil
    }
}

/// Tracks quoted strings, comments, and angle brackets while scanning structured header text character by character.
private struct StructuredTextScanner {
    private(set) var commentDepth = 0
    private(set) var inAngleBrackets = false
    private var inQuotes = false
    private var escaped = false

    /// Feeds one character and reports whether it is outside quotes and comments (and not an escape or delimiter
    /// of one), so the caller may treat it as syntax.
    mutating func isAtTopLevel(after character: Character) -> Bool {
        if escaped {
            escaped = false
            return false
        }
        if inQuotes || commentDepth > 0 {
            consumeNested(character)
            return false
        }
        switch character {
        case "\"":
            inQuotes = true
            return false
        case "(":
            commentDepth = 1
            return false
        case "<":
            inAngleBrackets = true
        case ">":
            inAngleBrackets = false
        default:
            break
        }
        return true
    }

    private mutating func consumeNested(_ character: Character) {
        switch character {
        case "\\":
            escaped = true
        case "\"" where inQuotes:
            inQuotes = false
        case "(" where !inQuotes:
            commentDepth += 1
        case ")" where !inQuotes:
            commentDepth -= 1
        default:
            break
        }
    }
}
