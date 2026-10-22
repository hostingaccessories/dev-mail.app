import DevMailCore
import SwiftUI

/// The sidebar list of received messages.
struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<MessageSummary.ID>

    var body: some View {
        List(model.filteredSummaries, selection: $selection) { summary in
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.subject ?? "(No Subject)")
                    .fontWeight(summary.isRead ? .regular : .semibold)
                    .lineLimit(1)
                Text(summary.sender?.displayString ?? "(Unknown Sender)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
