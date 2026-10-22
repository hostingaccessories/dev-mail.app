import AppKit
import DevMailCore
import SwiftUI

/// The selected message: header, attachments and body (HTML, plain text or source).
struct MessageDetailView: View {
    let summary: MessageSummary

    @Environment(AppModel.self) private var model

    /// The body mode the user last picked. Applied to each message that supports it; others fall back to the default.
    @SceneStorage("MessageDetail.bodyMode") private var preferredMode: MessageBodyMode?

    /// Tagged with the message ID, so a result for a previous selection is never shown under the new one.
    @State private var load: LoadResult?

    private struct LoadResult {
        let id: UUID
        let state: LoadState
    }

    private enum LoadState {
        case loaded(ParsedMessage, source: String)
        case failed(String)
    }

    var body: some View {
        Group {
            if let load, load.id == summary.id {
                switch load.state {
                case .loaded(let message, let source):
                    content(message: message, source: source)
                        .id(load.id)
                case .failed(let reason):
                    ContentUnavailableView(
                        "Couldn't Load Message",
                        systemImage: "exclamationmark.triangle",
                        description: Text(reason)
                    )
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: summary.id) {
            await loadMessage(id: summary.id)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Show in Finder", systemImage: "folder", action: showInFinder)
                    .help("Show in Finder")
                Button("Open in Mail", systemImage: "envelope.arrow.triangle.branch", action: openInMail)
                    .help("Open in Mail")
                Button("Delete", systemImage: "trash", action: delete)
                    .help("Delete")
            }
        }
    }

    private func content(message: ParsedMessage, source: String) -> some View {
        let mode = Binding(
            get: { MessageBodyMode.resolved(preferred: preferredMode, for: message) },
            set: { preferredMode = $0 }
        )
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                MessageHeaderView(message: message, summary: summary)
                Picker("View", selection: mode) {
                    ForEach(MessageBodyMode.availableModes(for: message)) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding()

            if !message.attachments.isEmpty {
                Divider()
                AttachmentsView(attachments: message.attachments, messageID: summary.id)
            }

            Divider()
            MessageBodyView(message: message, source: source, mode: mode.wrappedValue) {
                preferredMode = .html
            }
        }
    }

    private func loadMessage(id: UUID) async {
        do {
            let message = try await model.parsedMessage(for: id)
            // Off the main actor: a multi-megabyte source takes noticeable time to decode. Lenient on purpose:
            // invalid UTF-8 becomes U+FFFD so the source of a malformed message can still be inspected.
            let rawSource = message.rawSource
            let source = await Task.detached(priority: .userInitiated) {
                // swiftlint:disable:next optional_data_string_conversion
                String(decoding: rawSource, as: UTF8.self)
            }.value
            guard !Task.isCancelled else { return }
            load = LoadResult(id: id, state: .loaded(message, source: source))
        } catch {
            guard !Task.isCancelled else { return }
            load = LoadResult(id: id, state: .failed(error.localizedDescription))
        }
    }

    // MARK: - Actions

    private func delete() {
        let id = summary.id
        Task { await model.delete(ids: [id]) }
    }

    private func showInFinder() {
        withFileURL(failureTitle: "Couldn't Show Message in Finder") { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Opens the `.eml` in Mail, or in the default app for `.eml` files if Mail isn't installed.
    private func openInMail() {
        let model = model
        withFileURL(failureTitle: "Couldn't Open Message") { url in
            guard let mail = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else {
                NSWorkspace.shared.open(url)
                return
            }
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: mail,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in
                    model.lastError = AppError(title: "Couldn't Open Message", message: message)
                }
            }
        }
    }

    private func withFileURL(failureTitle: String, _ action: @escaping (URL) -> Void) {
        let id = summary.id
        Task {
            do {
                action(try await model.fileURL(for: id))
            } catch {
                model.lastError = AppError(title: failureTitle, message: error.localizedDescription)
            }
        }
    }
}

/// The message body in the chosen mode.
private struct MessageBodyView: View {
    let message: ParsedMessage
    let source: String
    let mode: MessageBodyMode
    let showHTML: () -> Void

    var body: some View {
        switch mode {
        case .html:
            MessageHTMLView(message: message)
        case .plainText:
            if let textBody = message.textBody {
                ReadOnlyTextView(text: textBody, font: .systemFont(ofSize: NSFont.systemFontSize))
            } else if message.htmlBody != nil {
                ContentUnavailableView {
                    Label("No Plain Text Part", systemImage: "doc.plaintext")
                } description: {
                    Text("This message only has an HTML body.")
                } actions: {
                    Button("Show HTML", action: showHTML)
                }
            } else {
                ContentUnavailableView("No Message Body", systemImage: "doc.plaintext")
            }
        case .source:
            ReadOnlyTextView(
                text: source,
                font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            )
        }
    }
}
