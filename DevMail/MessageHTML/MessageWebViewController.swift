import AppKit
import DevMailCore
import WebKit

/// Owns a locked-down `WKWebView` and renders one message's HTML into it at a time.
///
/// - JavaScript off, no script-opened windows, no link previews.
/// - Non-persistent data store per web view.
/// - Remote loads blocked by `RemoteContentRuleList` and a CSP unless allowed for the current message.
/// - `cid:` served from the message's inline parts; local files are never reachable (nil base URL).
/// - The web view never navigates: link clicks open in the default app, everything else is cancelled.
final class MessageWebViewController: NSObject {
    let webView: WKWebView

    private let cidHandler = CIDSchemeHandler()
    private var currentRequest: RenderRequest?
    private var generation = 0
    private var pendingLoads: [(navigation: WKNavigation, continuation: CheckedContinuation<Void, Never>)] = []

    private struct RenderRequest: Equatable {
        var message: ParsedMessage?
        var allowsRemoteContent: Bool
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: CIDURL.scheme)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false

        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Loads the message's HTML body (or an empty document if it has none) and returns when the load finishes, fails
    /// or is superseded by a later call. Calling again with the same arguments does nothing.
    func render(message: ParsedMessage?, allowsRemoteContent: Bool) async {
        let request = RenderRequest(message: message, allowsRemoteContent: allowsRemoteContent)
        guard request != currentRequest else { return }
        currentRequest = request
        generation += 1
        let thisGeneration = generation

        let ruleList = await RemoteContentRuleList.shared()
        guard thisGeneration == generation else { return }

        // The rule list must be in place before the load starts. If it failed to compile, the CSP still blocks
        // remote resources.
        let contentController = webView.configuration.userContentController
        contentController.removeAllContentRuleLists()
        if !allowsRemoteContent, let ruleList {
            contentController.add(ruleList)
        }

        cidHandler.message = message
        resumePendingLoads()

        let document = MessageContentSecurityPolicy.document(
            html: message?.htmlBody ?? "",
            allowsRemoteContent: allowsRemoteContent
        )
        guard let navigation = webView.loadHTMLString(document, baseURL: nil) else { return }
        await withCheckedContinuation { continuation in
            pendingLoads.append((navigation, continuation))
        }
    }

    /// Stops any in-flight load, e.g. when the hosting view goes away.
    func stop() {
        generation += 1
        currentRequest = nil
        webView.stopLoading()
        resumePendingLoads()
    }

    private func finishLoad(_ navigation: WKNavigation?) {
        guard let index = pendingLoads.firstIndex(where: { $0.navigation === navigation }) else { return }
        pendingLoads.remove(at: index).continuation.resume()
    }

    private func resumePendingLoads() {
        let loads = pendingLoads
        pendingLoads.removeAll()
        for load in loads {
            load.continuation.resume()
        }
    }

    private func apply(_ decision: MessageNavigationDecision) -> WKNavigationActionPolicy {
        switch decision {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}

extension MessageWebViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let decision = MessageNavigationPolicy.decision(
            for: navigationAction.request.url,
            isLinkActivation: navigationAction.navigationType == .linkActivated,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false
        )
        return apply(decision)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finishLoad(navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        finishLoad(navigation)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        finishLoad(navigation)
    }
}

extension MessageWebViewController: WKUIDelegate {
    // `target="_blank"` links and "Open Link in New Window" land here. Never create a window; treat link clicks
    // like any other link.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated {
            let decision = MessageNavigationPolicy.decision(
                for: navigationAction.request.url,
                isLinkActivation: true,
                isMainFrame: false
            )
            _ = apply(decision)
        }
        return nil
    }
}
