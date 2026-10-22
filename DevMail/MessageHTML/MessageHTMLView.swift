import AppKit
import DevMailCore
import SwiftUI
import WebKit

/// Renders a message's HTML body safely. Captured mail is untrusted: see `MessageWebViewController` for the
/// restrictions applied. Remote content is blocked until the user allows it, for this message only.
///
/// Use only for messages with an `htmlBody`; without one it renders an empty document.
struct MessageHTMLView: View {
    let message: ParsedMessage

    /// The message the user allowed remote content for. Comparing against the message (rather than storing a flag)
    /// means switching messages can never load the next one with remote content enabled, even for one frame.
    @State private var remoteContentAllowedFor: ParsedMessage?

    private var allowsRemoteContent: Bool {
        remoteContentAllowedFor == message
    }

    private var hasRemoteContent: Bool {
        message.htmlBody.map(RemoteContentDetector.containsRemoteContent) ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasRemoteContent && !allowsRemoteContent {
                RemoteContentBar {
                    remoteContentAllowedFor = message
                }
                Divider()
            }
            MessageWebView(message: message, allowsRemoteContent: allowsRemoteContent)
        }
    }
}

private struct RemoteContentBar: View {
    let loadRemoteContent: () -> Void

    var body: some View {
        HStack {
            Label("Remote content blocked", systemImage: "eye.slash")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Load Remote Content", action: loadRemoteContent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct MessageWebView: NSViewRepresentable {
    let message: ParsedMessage
    let allowsRemoteContent: Bool

    func makeCoordinator() -> MessageWebViewController {
        MessageWebViewController()
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let controller = context.coordinator
        let message = message
        let allowsRemoteContent = allowsRemoteContent
        Task {
            await controller.render(message: message, allowsRemoteContent: allowsRemoteContent)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: MessageWebViewController) {
        coordinator.stop()
    }
}

#Preview {
    MessageHTMLView(message: .htmlPreview)
        .frame(width: 600, height: 400)
}

extension ParsedMessage {
    /// A message with a `cid:` image and a remote tracking pixel, for previews.
    fileprivate static var htmlPreview: ParsedMessage {
        let html = """
            <!DOCTYPE html>
            <html>
            <body style="font-family: -apple-system; padding: 16px">
              <h1>Welcome aboard</h1>
              <p>The square below is an inline <code>cid:</code> image.</p>
              <img src="cid:logo@example.com" width="64" height="64" alt="Logo">
              <p>A <a href="https://example.com">link</a> opens in your browser.</p>
              <img src="https://tracker.example.com/pixel.gif" width="1" height="1" alt="">
              <script>document.body.innerHTML = "Scripts should never run";</script>
            </body>
            </html>
            """
        let logo = MessagePart(mimeType: "image/png", contentID: "logo@example.com", data: previewPNG())
        return ParsedMessage(subject: "Welcome", htmlBody: html, inlineParts: [logo])
    }

    private static func previewPNG() -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
}
