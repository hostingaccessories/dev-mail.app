import SwiftUI

@main
struct DevMailApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single window: closing it leaves the app running and catching mail; the Dock icon, Window menu, or ⌘0
        // reopens it.
        Window("Dev Mail", id: Self.mainWindowID) {
            ContentView()
                .environment(appDelegate.model)
                .modifier(MainWindowOpenerRegistration(appDelegate: appDelegate))
        }
        // A standard resizable window: only ContentView's minimum size constrains it, never the message's content.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            ServerCommands(model: appDelegate.model)
            MessageCommands(model: appDelegate.model)
            WindowCommands()
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

/// Gives the app delegate SwiftUI's `openWindow`, which it needs to reopen the main window from a Dock click.
private struct MainWindowOpenerRegistration: ViewModifier {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            appDelegate.openMainWindow = { [openWindow] in openWindow(id: DevMailApp.mainWindowID) }
        }
    }
}
