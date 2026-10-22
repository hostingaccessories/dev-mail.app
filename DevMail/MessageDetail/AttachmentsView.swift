import AppKit
import DevMailCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Lists a message's attachments with Quick Look (space bar or double-click), Save As… and drag to Finder.
///
/// Attachments are only ever handed to the system as quarantined files in `AttachmentFileStore`; they are never
/// opened in another app from here.
struct AttachmentsView: View {
    let attachments: [MessagePart]
    let messageID: UUID

    @Environment(AppModel.self) private var model
    @State private var selection: Int?
    @State private var previewURL: URL?

    private static let rowHeight: CGFloat = 40
    private static let visibleRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summaryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            List(selection: $selection) {
                ForEach(attachments.indices, id: \.self) { index in
                    AttachmentRow(
                        part: attachments[index],
                        preview: { preview(index) },
                        save: { save(index) }
                    )
                    .onDrag { dragProvider(for: index) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: Self.rowHeight * CGFloat(min(attachments.count, Self.visibleRows)))
            .contextMenu(forSelectionType: Int.self) { indices in
                if let index = indices.first {
                    Button("Quick Look") { preview(index) }
                    Button("Save As…") { save(index) }
                }
            } primaryAction: { indices in
                if let index = indices.first {
                    preview(index)
                }
            }
            .onKeyPress(.space) {
                guard let selection else { return .ignored }
                if previewURL == nil {
                    preview(selection)
                } else {
                    previewURL = nil
                }
                return .handled
            }
        }
        .quickLookPreview($previewURL)
    }

    private var summaryText: String {
        let total = attachments.reduce(0) { $0 + $1.size }
        let count = attachments.count == 1 ? "1 Attachment" : "\(attachments.count) Attachments"
        return "\(count), \(Int64(total).formatted(.byteCount(style: .file)))"
    }

    private func preview(_ index: Int) {
        selection = index
        do {
            previewURL = try AttachmentFileStore.shared.previewURL(
                for: attachments[index],
                index: index,
                messageID: messageID
            )
        } catch {
            model.lastError = AppError(title: "Couldn't Preview Attachment", message: error.localizedDescription)
        }
    }

    private func save(_ index: Int) {
        let part = attachments[index]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = part.safeFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        Task {
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, let url = panel.url else { return }
            do {
                try part.data.write(to: url, options: .atomic)
                try AttachmentFileStore.quarantine(url)
            } catch {
                model.lastError = AppError(title: "Couldn't Save Attachment", message: error.localizedDescription)
            }
        }
    }

    /// Finder copies the quarantined temporary file, so the dropped copy keeps the quarantine attribute.
    private func dragProvider(for index: Int) -> NSItemProvider {
        let part = attachments[index]
        do {
            let url = try AttachmentFileStore.shared.fileURL(for: part, index: index, messageID: messageID)
            if let provider = NSItemProvider(contentsOf: url) {
                provider.suggestedName = part.safeFilename
                return provider
            }
        } catch {
            model.lastError = AppError(title: "Couldn't Drag Attachment", message: error.localizedDescription)
        }
        return NSItemProvider()
    }
}

private struct AttachmentRow: View {
    let part: MessagePart
    let preview: () -> Void
    let save: () -> Void

    var body: some View {
        let contentType = part.contentType
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: contentType))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(part.safeFilename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details(for: contentType))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Quick Look", systemImage: "eye", action: preview)
                .help("Quick Look")
            Button("Save As…", systemImage: "square.and.arrow.down", action: save)
                .help("Save As…")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(part.mimeType)
    }

    private func details(for contentType: UTType) -> String {
        let kind = contentType.localizedDescription ?? part.mimeType
        return "\(Int64(part.size).formatted(.byteCount(style: .file))) · \(kind)"
    }
}
