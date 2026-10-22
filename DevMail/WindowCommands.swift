import SwiftUI

/// Adds a Window menu item that reopens the main window, which SwiftUI doesn't list on its own.
struct WindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Dev Mail") {
                openWindow(id: DevMailApp.mainWindowID)
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
