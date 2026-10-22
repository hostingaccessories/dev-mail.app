import SwiftUI

/// The Updates section of the Settings window.
struct UpdatesSettingsSection: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
        }
    }
}
