import DevMailCore
import SwiftUI

/// The Message menu. Acts on the main window's selection, so its items are disabled while the window is closed.
struct MessageCommands: Commands {
    let model: AppModel

    @FocusedBinding(\.messageSelection) private var selection
    @FocusedBinding(\.isConfirmingClearAll) private var isConfirmingClearAll

    var body: some Commands {
        CommandMenu("Message") {
            let ids = selection ?? []
            if MessageListSelection.shouldMarkRead(ids, in: model.summaries) {
                Button("Mark as Read") {
                    Task { await model.setRead(true, ids: ids) }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            } else {
                Button("Mark as Unread") {
                    Task { await model.setRead(false, ids: ids) }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(ids.isEmpty)
            }

            Divider()

            Button("Clear All…") {
                isConfirmingClearAll = true
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(isConfirmingClearAll == nil || model.summaries.isEmpty)
        }
    }
}
