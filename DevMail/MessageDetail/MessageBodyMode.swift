import DevMailCore

/// How the detail view shows a message's body.
nonisolated enum MessageBodyMode: String, CaseIterable, Identifiable, Sendable {
    case html
    case plainText
    case source

    var id: Self { self }

    var title: String {
        switch self {
        case .html: "HTML"
        case .plainText: "Plain Text"
        case .source: "Source"
        }
    }

    /// HTML needs an HTML body. Plain Text is always offered and explains when there is no text part.
    static func availableModes(for message: ParsedMessage) -> [MessageBodyMode] {
        message.htmlBody == nil ? [.plainText, .source] : allCases
    }

    /// The user's last choice when this message supports it, otherwise HTML if there is an HTML body, else Plain Text.
    static func resolved(preferred: MessageBodyMode?, for message: ParsedMessage) -> MessageBodyMode {
        let available = availableModes(for: message)
        if let preferred, available.contains(preferred) {
            return preferred
        }
        return available.contains(.html) ? .html : .plainText
    }
}
