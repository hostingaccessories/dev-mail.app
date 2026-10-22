import DevMailCore
import SwiftUI

/// One message in the sidebar list. Deliberately cheap — no per-row state or async work — so long lists stay smooth.
struct MessageRowView: View {
    let summary: MessageSummary

    /// `.increased` while the row is selected, where the accent-coloured unread dot would vanish into the highlight.
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(backgroundProminence == .increased ? Color.white : Color.accentColor)
                .opacity(summary.isRead ? 0 : 1)
                .accessibilityLabel("Unread")
                .accessibilityHidden(summary.isRead)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(summary.senderDisplayName)
                        .fontWeight(summary.isRead ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(summary.date, format: MessageDateStyle(for: summary.date).formatStyle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(summary.displaySubject)
                        .fontWeight(summary.isRead ? .regular : .semibold)
                        .lineLimit(1)
                    if summary.hasAttachments {
                        Spacer(minLength: 4)
                        Image(systemName: "paperclip")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Has attachments")
                    }
                }

                if !summary.snippet.isEmpty {
                    Text(summary.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
