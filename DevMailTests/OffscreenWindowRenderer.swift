import AppKit
import SwiftUI
import WebKit

/// Draws SwiftUI content in a window positioned offscreen and returns it as a PNG, including the title bar and
/// toolbar. `WKWebView` content is drawn out of process and missing from `cacheDisplay`, so each web view is
/// snapshotted separately and composited in.
@MainActor
enum OffscreenWindowRenderer {
    /// `toolbar` bridges the content's toolbar items and title into the window.
    static func png(of content: some View, size: CGSize, appearance: NSAppearance?, toolbar: Bool) async throws -> Data
    {
        let controller = NSHostingController(rootView: content)
        controller.sceneBridgingOptions = toolbar ? .all : []
        // Keep the requested size instead of growing the window to fit the content.
        controller.sizingOptions = []
        let window = OffscreenWindow(
            contentRect: NSRect(origin: OffscreenWindow.origin, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.title = "Dev Mail"
        window.contentViewController = controller
        window.setFrame(NSRect(origin: OffscreenWindow.origin, size: size), display: false)
        window.orderFrontRegardless()
        defer { window.close() }

        // Let SwiftUI load data (`.task`), lay out and finish web view loads.
        try await settle(window)

        guard let frameView = window.contentView?.superview else { throw SnapshotError("Window has no frame view") }
        frameView.layoutSubtreeIfNeeded()
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            throw SnapshotError("Couldn't create a bitmap")
        }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        if #available(macOS 26, *) {
            drawGlassContent(in: frameView, onto: bitmap)
        }
        try await compositeWebViews(in: frameView, onto: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError("Couldn't encode PNG")
        }
        return png
    }

    private static func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(500))
        let deadline = ContinuousClock.now + .seconds(10)
        while descendants(of: window.contentView, ofType: WKWebView.self).contains(where: \.isLoading),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(500))
        window.displayIfNeeded()
    }

    /// Liquid Glass (the sidebar, toolbar items) is composited by the window server, so `cacheDisplay` leaves it blank.
    /// Redraw each glass view's content over a plain window background instead. The glass material isn't shown, and
    /// its content may be drawn in the light appearance.
    @available(macOS 26, *)
    private static func drawGlassContent(in frameView: NSView, onto bitmap: NSBitmapImageRep) {
        let glassViews = descendants(of: frameView, ofType: NSGlassEffectView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
        guard !glassViews.isEmpty, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        for glass in glassViews {
            guard let content = glass.contentView,
                let contentBitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else { continue }
            content.cacheDisplay(in: content.bounds, to: contentBitmap)
            let rect = bitmapRect(of: content, in: frameView)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            frameView.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
            }
            contentBitmap.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func compositeWebViews(in frameView: NSView, onto bitmap: NSBitmapImageRep) async throws {
        let views = descendants(of: frameView, ofType: WKWebView.self)
        guard !views.isEmpty else { return }
        var images: [(NSImage, NSRect)] = []
        for webView in views where !webView.isHiddenOrHasHiddenAncestor && !webView.bounds.isEmpty {
            let image = try await webView.takeSnapshot(configuration: nil)
            images.append((image, bitmapRect(of: webView, in: frameView)))
        }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (image, rect) in images {
            image.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `view`'s frame in the bitmap's coordinate space (origin at the bottom left of `frameView`).
    private static func bitmapRect(of view: NSView, in frameView: NSView) -> NSRect {
        let rect = view.convert(view.bounds, to: frameView)
        guard frameView.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: frameView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Views of type `T` under `view`, not looking inside a match.
    private static func descendants<T: NSView>(of view: NSView?, ofType type: T.Type) -> [T] {
        guard let view else { return [] }
        if let match = view as? T { return [match] }
        return view.subviews.flatMap { descendants(of: $0, ofType: type) }
    }
}

/// A window that sits entirely offscreen. AppKit otherwise moves titled windows back onto a screen.
///
/// With no screen to limit it, SwiftUI grows the window to the content's minimum size, so a snapshot taller than
/// requested means the content can't fit the requested size.
private final class OffscreenWindow: NSWindow {
    static let origin = NSPoint(x: -20_000, y: -20_000)

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

struct SnapshotError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
