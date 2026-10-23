import Foundation

/// Resolves message IDs typed on the command line, which may be a unique prefix of a UUID like a short Git hash.
public enum MessageIDMatcher {
    /// How many characters of an ID `mail list` shows.
    public static let shortLength = 8

    public enum MatchError: Error, Equatable, LocalizedError {
        case invalid(String)
        case notFound(String)
        case ambiguous(String, matches: Int)

        public var errorDescription: String? {
            switch self {
            case .invalid(let id):
                "\"\(id)\" is not a message ID."
            case .notFound(let id):
                "No message with ID \(id)."
            case .ambiguous(let id, let matches):
                "\(matches) messages have IDs starting with \(id); use more characters."
            }
        }
    }

    /// The first `shortLength` characters of `id`, lowercased.
    public static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(shortLength))
    }

    /// The one ID in `candidates` that `text` is a full ID or case-insensitive prefix of.
    public static func match(_ text: String, in candidates: some Sequence<UUID>) throws(MatchError) -> UUID {
        let prefix = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw .invalid(text) }

        var found: UUID?
        var count = 0
        for id in candidates where id.uuidString.lowercased().hasPrefix(prefix) {
            found = id
            count += 1
        }
        guard let found else { throw .notFound(text) }
        guard count == 1 else { throw .ambiguous(text, matches: count) }
        return found
    }
}
