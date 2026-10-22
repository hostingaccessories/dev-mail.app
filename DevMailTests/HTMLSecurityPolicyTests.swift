import DevMailCore
import Foundation
import Testing

@testable import DevMail

struct MessageContentSecurityPolicyTests {
    @Test func blocksRemoteByDefault() {
        let policy = MessageContentSecurityPolicy.policy(allowsRemoteContent: false)

        #expect(
            policy
                == "default-src 'none'; img-src cid: data:; style-src 'unsafe-inline' cid: data:; "
                + "font-src cid: data:; media-src cid: data:; form-action 'none'; base-uri 'none'"
        )
    }

    @Test func allowsRemoteResourcesWhenRequested() {
        let policy = MessageContentSecurityPolicy.policy(allowsRemoteContent: true)

        #expect(policy.contains("img-src cid: data: https: http:"))
        #expect(policy.contains("style-src 'unsafe-inline' cid: data: https: http:"))
        #expect(policy.contains("font-src cid: data: https: http:"))
        #expect(policy.contains("media-src cid: data: https: http:"))
        #expect(policy.contains("default-src 'none'"))
    }

    @Test(arguments: [false, true])
    func neverAllowsScripts(allowsRemoteContent: Bool) {
        let policy = MessageContentSecurityPolicy.policy(allowsRemoteContent: allowsRemoteContent)

        #expect(!policy.contains("script-src"))
        #expect(!policy.contains("unsafe-eval"))
    }

    @Test func injectsMetaAtStart() {
        let document = MessageContentSecurityPolicy.document(html: "<p>Hi</p>", allowsRemoteContent: false)

        #expect(document.hasPrefix("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none';"))
        #expect(document.hasSuffix("\"><p>Hi</p>"))
    }

    @Test func keepsDoctypeFirst() {
        let html = "\n  <!DOCTYPE html><html><head><script>x()</script></head></html>"

        let document = MessageContentSecurityPolicy.document(html: html, allowsRemoteContent: false)

        #expect(document.hasPrefix("<!DOCTYPE html><meta http-equiv=\"Content-Security-Policy\""))
        #expect(document.hasSuffix("\"><html><head><script>x()</script></head></html>"))
    }
}

struct RemoteContentDetectorTests {
    @Test(arguments: [
        #"<img src="https://tracker.example.com/open.gif" width="1" height="1">"#,
        "<IMG SRC=http://tracker.example.com/open.gif>",
        #"<td style="background-image: url('https://cdn.example.com/bg.png')">"#,
        #"<style>body { background: url(http://cdn.example.com/bg.png) }</style>"#,
        #"<style>@import "https://fonts.example.com/font.css";</style>"#,
        #"<img src="cid:logo" srcset="cid:logo 1x, https://cdn.example.com/logo@2x.png 2x">"#,
        #"<link rel="stylesheet" href="https://cdn.example.com/mail.css">"#,
        #"<table background="https://cdn.example.com/bg.png">"#,
        #"<video poster="https://cdn.example.com/poster.jpg"></video>"#,
    ])
    func detectsRemoteResources(html: String) {
        #expect(RemoteContentDetector.containsRemoteContent(html))
    }

    @Test(arguments: [
        "Plain text mentioning https://example.com without markup",
        #"<p>Visit <a href="https://example.com">our site</a></p>"#,
        #"<img src="cid:logo@example.com"><img src="data:image/png;base64,iVBORw0KGgo=">"#,
        #"<div style="color: red">No remote resources</div>"#,
        "",
    ])
    func ignoresLocalContentAndLinks(html: String) {
        #expect(!RemoteContentDetector.containsRemoteContent(html))
    }
}

struct MessageNavigationPolicyTests {
    @Test(arguments: ["https://example.com/path", "http://example.com", "mailto:someone@example.com"])
    func opensSafeLinksExternally(link: String) throws {
        let url = try #require(URL(string: link))

        let decision = MessageNavigationPolicy.decision(for: url, isLinkActivation: true, isMainFrame: true)

        #expect(decision == .openExternally(url))
    }

    @Test(arguments: [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "cid:logo@example.com",
        "data:text/html,hi",
        "x-custom-app://open",
        "ftp://example.com/file",
        "about:blank",
    ])
    func blocksOtherLinks(link: String) throws {
        let url = try #require(URL(string: link))

        let decision = MessageNavigationPolicy.decision(for: url, isLinkActivation: true, isMainFrame: true)

        #expect(decision == .cancel)
    }

    @Test func allowsInitialLoad() throws {
        let url = try #require(URL(string: "about:blank"))

        #expect(MessageNavigationPolicy.decision(for: url, isLinkActivation: false, isMainFrame: true) == .allow)
    }

    @Test(arguments: [
        ("https://example.com", true),
        ("file:///Users/someone/Desktop/mail.html", true),
        ("data:text/html,hi", true),
        ("about:blank", false),
        ("https://example.com/frame", false),
    ])
    func cancelsOtherNavigations(link: String, isMainFrame: Bool) throws {
        let url = try #require(URL(string: link))

        let decision = MessageNavigationPolicy.decision(for: url, isLinkActivation: false, isMainFrame: isMainFrame)

        #expect(decision == .cancel)
    }

    @Test func cancelsNavigationWithoutURL() {
        #expect(MessageNavigationPolicy.decision(for: nil, isLinkActivation: true, isMainFrame: true) == .cancel)
    }
}

struct CIDURLTests {
    let logo = MessagePart(mimeType: "image/png", contentID: "logo@example.com", data: Data([1, 2, 3]))
    let banner = MessagePart(mimeType: "image/jpeg", contentID: "part1.06090408 01060107", data: Data([4]))

    var message: ParsedMessage {
        ParsedMessage(htmlBody: "<img src=\"cid:logo@example.com\">", inlineParts: [logo, banner])
    }

    @Test func extractsContentID() throws {
        let url = try #require(URL(string: "cid:logo@example.com"))

        #expect(CIDURL.contentID(from: url) == "logo@example.com")
    }

    @Test func percentDecodesContentID() throws {
        let url = try #require(URL(string: "cid:part1.06090408%2001060107"))

        #expect(CIDURL.contentID(from: url) == "part1.06090408 01060107")
        #expect(CIDURL.inlinePart(for: url, in: message) == banner)
    }

    @Test func resolvesContentIDWithAngleBrackets() throws {
        let url = try #require(URL(string: "cid:%3Clogo@example.com%3E"))

        #expect(CIDURL.inlinePart(for: url, in: message) == logo)
    }

    @Test func schemeIsCaseInsensitive() throws {
        let url = try #require(URL(string: "CID:logo@example.com"))

        #expect(CIDURL.inlinePart(for: url, in: message) == logo)
    }

    @Test(arguments: ["cid:missing@example.com", "cid:", "https://example.com/logo.png", "data:image/png,"])
    func returnsNilForUnknownOrNonCIDURLs(link: String) throws {
        let url = try #require(URL(string: link))

        #expect(CIDURL.inlinePart(for: url, in: message) == nil)
    }
}

struct CIDContentTypePolicyTests {
    @Test(arguments: [
        "image/png", "image/jpeg", "image/gif", "image/webp", "IMAGE/PNG", "image/png; name=logo.png",
        "font/woff2", "font/ttf", "text/css", "text/css; charset=utf-8", "audio/mpeg", "video/mp4",
    ])
    func allowsSubresourceTypes(mimeType: String) {
        #expect(CIDContentTypePolicy.allows(mimeType: mimeType))
    }

    @Test(arguments: [
        "image/svg+xml", "IMAGE/SVG+XML", "image/svg+xml; charset=utf-8", "text/html", "text/plain",
        "text/javascript", "application/javascript", "application/xhtml+xml", "application/xml", "text/xml",
        "application/pdf", "application/octet-stream", "multipart/related", "image", "image/", "/png", "",
    ])
    func refusesEverythingElse(mimeType: String) {
        #expect(!CIDContentTypePolicy.allows(mimeType: mimeType))
    }
}
