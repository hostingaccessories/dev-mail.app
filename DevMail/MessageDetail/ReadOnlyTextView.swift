import AppKit
import SwiftUI

/// Scrollable, selectable, non-editable text backed by `NSTextView`, which lays out lazily and stays responsive with
/// multi-megabyte message sources where a SwiftUI `Text` would not.
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    let font: NSFont

    final class Coordinator {
        var text: String?
        var font: NSFont?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.textContainerInset = NSSize(width: 8, height: 10)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard coordinator.text != text || coordinator.font != font else { return }

        coordinator.text = text
        coordinator.font = font
        textView.string = text
        textView.font = font
        textView.scroll(.zero)
    }
}
