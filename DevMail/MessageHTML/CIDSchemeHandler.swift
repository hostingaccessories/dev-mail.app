import DevMailCore
import WebKit

/// Serves `cid:` URLs from the current message's inline parts, limited to the subresource types that
/// `CIDContentTypePolicy` allows.
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    var message: ParsedMessage?

    // Every task is answered before this method returns, so no task is retained and none can be used after `stop`.
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard
            let url = urlSchemeTask.request.url,
            let message,
            let part = CIDURL.inlinePart(for: url, in: message),
            CIDContentTypePolicy.allows(mimeType: part.mimeType)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: part.mimeType,
            expectedContentLength: part.data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(part.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
