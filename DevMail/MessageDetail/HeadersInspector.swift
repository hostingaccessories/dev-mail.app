import AppKit
import DevMailCore
import SwiftUI

/// A trailing panel beside the message listing its headers, resized by dragging its leading edge.
struct HeadersPanel: View {
    /// `nil` while the message loads, so the previous message's headers never linger.
    let headers: [MessageHeader]?
    /// The width the user chose. Kept as is when `maxWidth` is smaller, so it comes back when the window widens.
    @Binding var width: Double
    /// The most room available, including the divider; the panel never shrinks below its minimum for it.
    let maxWidth: CGFloat

    static let defaultWidth: Double = 300
    /// Including the divider.
    static let minimumWidth: CGFloat = 221
    private static let preferredMaximumWidth: Double = 500
    private static let dividerWidth: Double = 1

    /// The width when the current drag began.
    @State private var dragStartWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            Divider()
                .overlay {
                    // Wider than the divider so it's easy to grab.
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .pointerStyle(.frameResize(position: .leading))
                        .gesture(resizeGesture)
                }
            Group {
                if let headers {
                    HeadersInspector(headers: headers)
                } else {
                    Color.clear
                }
            }
            .frame(width: clampedWidth)
            .frame(maxHeight: .infinity)
        }
    }

    private var widthRange: ClosedRange<Double> {
        let lower = Double(Self.minimumWidth) - Self.dividerWidth
        let upper = min(Self.preferredMaximumWidth, Double(maxWidth) - Self.dividerWidth)
        return lower...max(lower, upper)
    }

    private var clampedWidth: Double {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartWidth ?? clampedWidth
                dragStartWidth = start
                // Dragging left widens the panel.
                let proposed = start - value.translation.width
                width = min(max(proposed, widthRange.lowerBound), widthRange.upperBound)
            }
            .onEnded { _ in
                dragStartWidth = nil
            }
    }
}

/// Every top-level header of a message, in its original order, for the headers panel.
struct HeadersInspector: View {
    let headers: [MessageHeader]

    var body: some View {
        if headers.isEmpty {
            ContentUnavailableView("No Headers", systemImage: "list.bullet.rectangle")
        } else {
            ScrollView {
                // Indexed, not keyed by name: names repeat (Received, DKIM-Signature).
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(headers.indices, id: \.self) { index in
                        if index > 0 {
                            Divider()
                        }
                        HeaderEntry(header: headers[index])
                    }
                }
                .padding()
            }
        }
    }
}

private struct HeaderEntry: View {
    let header: MessageHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header.name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(header.value.isEmpty ? " " : header.value)
                .font(.callout.monospaced())
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .contextMenu {
            Button("Copy Header") { copy("\(header.name): \(header.value)") }
            Button("Copy Value") { copy(header.value) }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
