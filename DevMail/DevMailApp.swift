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
