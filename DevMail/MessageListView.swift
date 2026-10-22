import DevMailCore
import SwiftUI

/// The sidebar list of received messages.
struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<MessageSummary.ID>
    @State private var isConfirmingClearAll = false

    var body: some View {
        @Bindable var model = model
        let summaries = model.filteredSummaries

        List(summaries, selection: $selection) { summary in
            MessageRowView(summary: summary)
        }
        .contextMenu(forSelectionType: MessageSummary.ID.self) { ids in
            if !ids.isEmpty {
                contextMenu(for: ids)
            }
        }
        .onDeleteCommand(perform: selection.isEmpty ? nil : { delete(selection) })
        .onChange(of: selection) { _, newSelection in
            markReadIfOpened(newSelection)
        }
        .overlay {
            if summaries.isEmpty && !model.summaries.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar)
        .focusedSceneValue(\.messageSelection, $selection)
        .focusedSceneValue(\.isConfirmingClearAll, $isConfirmingClearAll)
        .confirmationDialog(
            "Delete all messages?",
            isPresented: $isConfirmingClearAll
        ) {
            Button("Delete All", role: .destructive) {
                selection = []
                Task { await model.deleteAll() }
            }
        } message: {
            Text("All received messages will be removed. This can't be undone.")
        }
    }

    @ViewBuilder private func contextMenu(for ids: Set<MessageSummary.ID>) -> some View {
        if MessageListSelection.shouldMarkRead(ids, in: model.summaries) {
            Button("Mark as Read") {
                Task { await model.setRead(true, ids: ids) }
            }
        } else {
            Button("Mark as Unread") {
                Task { await model.setRead(false, ids: ids) }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            delete(ids)
        }
    }

    /// Opening a single message marks it read; multi-selection leaves read state alone.
    private func markReadIfOpened(_ selection: Set<MessageSummary.ID>) {
        guard selection.count == 1, let id = selection.first,
            model.summaries.contains(where: { $0.id == id && !$0.isRead })
        else { return }
        Task { await model.markRead(id, isRead: true) }
    }

    private func delete(_ ids: Set<MessageSummary.ID>) {
        guard !ids.isEmpty else { return }
        // Move the selection before the rows disappear so the list doesn't fall back to selecting nothing.
        if !selection.isDisjoint(with: ids) {
            let remaining = selection.subtracting(ids)
            if remaining.isEmpty {
                let visibleIDs = model.filteredSummaries.map(\.id)
                selection = MessageListSelection.neighbour(afterDeleting: ids, in: visibleIDs).map { [$0] } ?? []
            } else {
                selection = remaining
            }
        }
        Task { await model.delete(ids: ids) }
    }
}
