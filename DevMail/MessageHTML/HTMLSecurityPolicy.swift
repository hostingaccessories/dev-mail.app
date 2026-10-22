import DevMailCore
import Foundation

/// Content-Security-Policy injected into every rendered message, as defense in depth behind the content rule list.
nonisolated enum MessageContentSecurityPolicy {
    /// The policy string. There is deliberately no `script-src`, so scripts fall back to `default-src 'none'`.
    static func policy(allowsRemoteContent: Bool) -> String {
        let sources = allowsRemoteContent ? "cid: data: https: http:" : "cid: data:"
        return [
            "default-src 'none'",
            "img-src \(sources)",
            "style-src 'unsafe-inline' \(sources)",
            "font-src \(sources)",
            "media-src \(sources)",
            "form-action 'none'",
            "base-uri 'none'",
        ]
        .joined(separator: "; ")
    }

    /// The message HTML with a CSP `<meta>` as its first element. A leading doctype is kept in front of it, since
    /// moving the doctype would switch the document into quirks mode; a doctype cannot load anything.
    static func document(html: String, allowsRemoteContent: Bool) -> String {
        let csp = policy(allowsRemoteContent: allowsRemoteContent)
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"

        let trimmed = html.drop { $0.isWhitespace }
        if trimmed.lowercased().hasPrefix("<!doctype"), let end = trimmed.firstIndex(of: ">") {
            let doctype = trimmed[...end]
            let rest = trimmed[trimmed.index(after: end)...]
            return doctype + meta + rest
        }
        return meta + html
    }
}

/// Decides whether a message references remote resources, to offer the "Load Remote Content" bar. This only drives
/// the UI; blocking is enforced by the content rule list and CSP regardless of what it finds.
nonisolated enum RemoteContentDetector {
    // Computed because Regex isn't Sendable, so it can't be stored in a static.
    private static var patterns: [Regex<Substring>] {
        [
            // src=, background=, poster= attributes.
            #/\b(?:src|background|poster)\s*=\s*["']?\s*https?:\/\//#.ignoresCase(),
            // Any candidate in a srcset list.
            #/\bsrcset\s*=\s*(?:"[^"]*|'[^']*|)https?:\/\//#.ignoresCase(),
            // CSS url(...) in style attributes or <style> blocks.
            #/url\(\s*["']?\s*https?:\/\//#.ignoresCase(),
            // CSS @import "..." without url().
            #/@import\s+["']\s*https?:\/\//#.ignoresCase(),
            // <link href=...> (stylesheets, fonts); <a href> is a link, not a resource.
            #/<link\b[^>]*\bhref\s*=\s*["']?\s*https?:\/\//#.ignoresCase(),
        ]
    }

    static func containsRemoteContent(_ html: String) -> Bool {
        patterns.contains { html.contains($0) }
    }
}

/// What to do with a navigation the web view asks about.
nonisolated enum MessageNavigationDecision: Equatable {
    case allow
    case cancel
    /// Cancel the navigation and hand the URL to the user's default app.
    case openExternally(URL)
}

/// The web view only ever shows the HTML we load into it; it never navigates on its own.
nonisolated enum MessageNavigationPolicy {
    static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// - Parameters:
    ///   - url: The navigation's target URL.
    ///   - isLinkActivation: The user clicked a link.
    ///   - isMainFrame: The navigation targets the main frame.
    static func decision(for url: URL?, isLinkActivation: Bool, isMainFrame: Bool) -> MessageNavigationDecision {
        guard let url else { return .cancel }

        if isLinkActivation {
            guard let scheme = url.scheme?.lowercased(), externalSchemes.contains(scheme) else { return .cancel }
            return .openExternally(url)
        }

        // `loadHTMLString(_:baseURL: nil)` loads the document as about:blank. Everything else (redirects, meta
        // refresh, form submissions, frames, dropped files) is refused.
        if isMainFrame && url.absoluteString == "about:blank" {
            return .allow
        }
        return .cancel
    }
}

/// Resolves `cid:` URLs (RFC 2392) to a message's inline parts.
nonisolated enum CIDURL {
    static let scheme = "cid"

    /// The Content-ID a `cid:` URL refers to, percent-decoded. Angle brackets, if any, are left for
    /// `ParsedMessage.inlinePart(contentID:)` to strip.
    static func contentID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        let encoded = url.absoluteString.dropFirst(scheme.count + 1)
        guard let contentID = String(encoded).removingPercentEncoding, !contentID.isEmpty else { return nil }
        return contentID
    }

    static func inlinePart(for url: URL, in message: ParsedMessage) -> MessagePart? {
        contentID(from: url).flatMap { message.inlinePart(contentID: $0) }
    }
}
