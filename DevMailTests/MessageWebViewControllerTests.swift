import AppKit
import DevMailCore
import Foundation
import Network
import Synchronization
import Testing
import WebKit

@testable import DevMail

/// Loads real HTML into the configured web view to check the restrictions WebKit enforces.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MessageWebViewControllerTests {
    @Test func doesNotRunScripts() async throws {
        let controller = MessageWebViewController()
        let html = """
            <html><head><title>untouched</title>
            <script>document.title = "inline script ran";</script>
            </head><body onload="document.title = 'onload ran'">
            <img src="cid:missing" onerror="document.title = 'onerror ran'">
            </body></html>
            """

        await controller.render(message: ParsedMessage(htmlBody: html), allowsRemoteContent: false)

        #expect(controller.webView.title == "untouched")
    }

    @Test func displaysCIDImages() async throws {
        let controller = MessageWebViewController()
        let png = try #require(Self.pngData())
        let message = ParsedMessage(
            htmlBody: #"<img id="logo" src="cid:%3Clogo@example.com%3E">"#,
            inlineParts: [MessagePart(mimeType: "image/png", contentID: "logo@example.com", data: png)]
        )

        await controller.render(message: message, allowsRemoteContent: false)

        // App-injected JavaScript still runs when content JavaScript is disabled.
        let width = try await controller.webView.evaluateJavaScript(
            "document.getElementById('logo').naturalWidth"
        )
        #expect(width as? Int == 4)
    }

    @Test func refusesCIDPartsWithDisallowedTypes() async throws {
        let controller = MessageWebViewController()
        let png = try #require(Self.pngData())
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"></svg>"#.utf8)
        let message = ParsedMessage(
            htmlBody: #"<img id="svg" src="cid:svg@example.com"><img id="html" src="cid:html@example.com">"#,
            inlineParts: [
                MessagePart(mimeType: "image/svg+xml", contentID: "svg@example.com", data: svg),
                MessagePart(mimeType: "text/html", contentID: "html@example.com", data: png),
            ]
        )

        await controller.render(message: message, allowsRemoteContent: false)

        let widths = try await controller.webView.evaluateJavaScript(
            "[document.getElementById('svg').naturalWidth, document.getElementById('html').naturalWidth]"
        )
        #expect(widths as? [Int] == [0, 0])
    }

    @Test func blocksTrackingPixelUntilAllowed() async throws {
        let server = try await ConnectionCounter.start()
        defer { server.stop() }
        let message = ParsedMessage(
            htmlBody: """
                <img src="http://127.0.0.1:\(server.port)/pixel.gif" width="1" height="1">
                <div style="background: url('http://127.0.0.1:\(server.port)/bg.png')">x</div>
                """
        )
        let controller = MessageWebViewController()

        await controller.render(message: message, allowsRemoteContent: false)
        #expect(server.connections == 0)

        // Confirms the blocked case above was meaningful: the same HTML does reach the server once allowed.
        Task { await controller.render(message: message, allowsRemoteContent: true) }
        let deadline = ContinuousClock.now + .seconds(20)
        while server.connections == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(server.connections > 0)
        controller.stop()
    }

    @Test func compilesRuleList() async {
        #expect(await RemoteContentRuleList.shared() != nil)
    }

    private static func pngData() -> Data? {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        bitmap.size = NSSize(width: 4, height: 4)
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// A localhost TCP listener that counts and immediately drops incoming connections.
private final class ConnectionCounter: Sendable {
    private let listener: NWListener
    private let count = Mutex(0)

    private init(listener: NWListener) {
        self.listener = listener
    }

    var connections: Int { count.withLock { $0 } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    static func start() async throws -> ConnectionCounter {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let counter = ConnectionCounter(listener: try NWListener(using: parameters))
        counter.listener.newConnectionHandler = { connection in
            counter.count.withLock { $0 += 1 }
            connection.cancel()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            counter.listener.stateUpdateHandler = { state in
                let result: Result<Void, any Error>
                switch state {
                case .ready: result = .success(())
                case .failed(let error): result = .failure(error)
                default: return
                }
                let isFirst = resumed.withLock { wasResumed in
                    defer { wasResumed = true }
                    return !wasResumed
                }
                if isFirst {
                    continuation.resume(with: result)
                }
            }
            counter.listener.start(queue: DispatchQueue(label: "ConnectionCounter"))
        }
        return counter
    }

    func stop() {
        listener.cancel()
    }
}
