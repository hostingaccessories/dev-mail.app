import SwiftUI

/// Adds a Window menu item that reopens the main window, which SwiftUI doesn't list on its own, and a View menu item
/// that toggles the headers panel.
struct WindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    @FocusedBinding(\.showsHeaders) private var showsHeaders

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(showsHeaders == true ? "Hide Headers" : "Show Headers") {
                showsHeaders?.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(showsHeaders == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Dev Mail") {
                openWindow(id: DevMailApp.mainWindowID)
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
