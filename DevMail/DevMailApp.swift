import SwiftUI

@main
struct DevMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single window: closing it leaves the app running and catching mail; the Dock icon reopens it.
        Window("Dev Mail", id: "main") {
            ContentView()
                .environment(appDelegate.model)
        }
        // A standard resizable window: only ContentView's minimum size constrains it, never the message's content.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            ServerCommands(model: appDelegate.model)
            MessageCommands(model: appDelegate.model)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}
