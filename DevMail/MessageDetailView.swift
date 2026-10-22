import DevMailCore
import SwiftUI

/// The selected message.
struct MessageDetailView: View {
    let summary: MessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.subject ?? "(No Subject)")
                .font(.title2)
            Text(summary.sender?.displayString ?? "(Unknown Sender)")
                .foregroundStyle(.secondary)
            Text(summary.snippet)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
