import OSLog
import WebKit

/// The compiled `WKContentRuleList` that blocks every load except `cid:`, `data:` and `about:` URLs.
enum RemoteContentRuleList {
    static let identifier = "com.hostingaccessories.DevMail.block-remote-content"

    /// Content blocker regexes don't support `|`, so each allowed scheme gets its own exception rule.
    static let encodedRules = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^cid:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """

    private static let logger = Logger(subsystem: "com.hostingaccessories.DevMail", category: "HTMLViewer")
    private static var cached: WKContentRuleList?
    private static var compileFailed = false

    /// Compiles the rule list on first use and caches it for the life of the process. Returns `nil` if it can't be
    /// compiled; callers still render, relying on the CSP alone to keep remote content out.
    static func shared() async -> WKContentRuleList? {
        if let cached { return cached }
        if compileFailed { return nil }

        do {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedRules
            )
            // Another caller may have finished compiling while this one was suspended; keep the first.
            if cached == nil { cached = list }
            return cached
        } catch {
            logger.error("Failed to compile remote content rule list: \(error.localizedDescription, privacy: .public)")
            compileFailed = true
            return nil
        }
    }
}
