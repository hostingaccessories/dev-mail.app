import AppKit
import DevMailCore
import SwiftUI

/// The Settings window. Edits apply when committed (Return, or moving focus to another control) rather than on every
/// keystroke, so typing a port doesn't restart the server once per digit.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private let userDefaults: UserDefaults

    /// The applied and saved settings. The text fields below are drafts until committed.
    @State private var settings: AppSettings
    @State private var hostText: String
    @State private var portText: String
    @State private var maxMessageCountText: String
    @State private var maxAgeInDaysText: String
    @State private var limitsMessageCount: Bool
    @State private var limitsMessageAge: Bool
    @State private var showsMenuBarItem: Bool
    @State private var hidesDockIcon: Bool
    @State private var openAtLogin: OpenAtLoginSetting

    /// Retention settings waiting for the user to confirm they may delete messages.
    @State private var pendingRetention: PendingRetention?

    @State private var isImportingDemoMessages = false

    @FocusState private var focusedField: Field?

    private enum Field {
        case host, port, maxMessageCount, maxAgeInDays
    }

    private struct PendingRetention {
        let settings: AppSettings
        let removedCount: Int
    }

    init(userDefaults: UserDefaults = .standard, openAtLogin: OpenAtLoginSetting = OpenAtLoginSetting()) {
        self.userDefaults = userDefaults
        _openAtLogin = State(initialValue: openAtLogin)
        let settings = AppSettings(userDefaults: userDefaults)
        _settings = State(initialValue: settings)
        _hostText = State(initialValue: settings.host)
        _portText = State(initialValue: String(settings.port))
        _maxMessageCountText = State(initialValue: String(settings.maxMessageCount))
        _maxAgeInDaysText = State(initialValue: String(settings.maxAgeInDays))
        _limitsMessageCount = State(initialValue: settings.limitsMessageCount)
        _limitsMessageAge = State(initialValue: settings.limitsMessageAge)
        _showsMenuBarItem = State(initialValue: settings.showsMenuBarItem)
        _hidesDockIcon = State(initialValue: settings.hidesDockIcon)
    }

    var body: some View {
        Form {
            generalSection
            serverSection
            menuBarSection
            retentionSection
            storageSection
            demoSection
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 880)
        .onChange(of: focusedField) { previous, _ in
            commit(previous)
        }
        .onChange(of: limitsMessageCount) { commitRetention() }
        .onChange(of: limitsMessageAge) { commitRetention() }
        .onChange(of: showsMenuBarItem) { commitMenuBar() }
        .onChange(of: hidesDockIcon) { commitMenuBar() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have changed the login item in System Settings.
            openAtLogin.refresh()
        }
        .onDisappear {
            // Closing the window doesn't always end editing first, so apply anything left. Deleting messages needs
            // the dialog, so those changes are dropped instead.
            commitServer()
            commitRetention(canAskToDelete: false)
            resetDrafts()
        }
        .confirmationDialog(
            pendingRetention.map { deletionTitle(count: $0.removedCount) } ?? "",
            isPresented: Binding(
                get: { pendingRetention != nil },
                set: { if !$0 { pendingRetention = nil } }
            ),
            presenting: pendingRetention
        ) { pending in
            Button("Delete", role: .destructive) {
                applyRetention(pending.settings)
            }
            Button("Cancel", role: .cancel) {
                resetRetentionDrafts()
            }
        } message: { _ in
            Text("Messages outside the new limits are deleted right away. This can't be undone.")
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section("SMTP Server") {
            TextField("Host", text: $hostText, prompt: Text(SMTPServerConfiguration().host))
                .autocorrectionDisabled()
                .focused($focusedField, equals: .host)
                .onSubmit { commitServer() }
            if let hostError {
                validationMessage(hostError)
            } else if !AppSettings.isLoopback(trimmedHost) {
                Label(
                    "Other devices on your network can send mail to Dev Mail.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }

            TextField("Port", text: $portText, prompt: Text(String(SMTPServerConfiguration().port)))
                .monospacedDigit()
                .focused($focusedField, equals: .port)
                .onSubmit { commitServer() }
            if AppSettings.parsePort(portText) == nil {
                validationMessage("Enter a port from 1 to 65535.")
            }

            LabeledContent("Status") {
                ServerStatusView()
            }

            HStack {
                Spacer()
                Button("Restore Defaults", action: restoreServerDefaults)
                    .disabled(isServerAtDefaults)
            }
        }
    }

    private var menuBarSection: some View {
        Section {
            Toggle("Show Dev Mail in the menu bar", isOn: $showsMenuBarItem)
            // Without the menu bar item, hiding the Dock icon would leave no way back into the app.
            Toggle("Hide Dock icon", isOn: $hidesDockIcon)
                .disabled(!showsMenuBarItem)
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("Dev Mail stays available from the menu bar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var retentionSection: some View {
        Section {
            Toggle("Keep only the most recent messages", isOn: $limitsMessageCount)
            TextField("Messages to keep", text: $maxMessageCountText)
                .monospacedDigit()
                .focused($focusedField, equals: .maxMessageCount)
                .onSubmit { commitRetention() }
                .disabled(!limitsMessageCount)
            if limitsMessageCount, AppSettings.parsePositiveInteger(maxMessageCountText) == nil {
                validationMessage("Enter a number of messages greater than 0.")
            }

            Toggle("Delete old messages", isOn: $limitsMessageAge)
            TextField("Delete after (days)", text: $maxAgeInDaysText)
                .monospacedDigit()
                .focused($focusedField, equals: .maxAgeInDays)
                .onSubmit { commitRetention() }
                .disabled(!limitsMessageAge)
            if limitsMessageAge, AppSettings.parsePositiveInteger(maxAgeInDaysText) == nil {
                validationMessage("Enter a number of days greater than 0.")
            }
        } header: {
            Text("Retention")
        } footer: {
            Text("The oldest messages are deleted first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func validationMessage(_ text: String) -> some View {
        Label(text, systemImage: "xmark.octagon")
            .foregroundStyle(.red)
    }

    // MARK: - Server

    private var trimmedHost: String {
        hostText.trimmingCharacters(in: .whitespaces)
    }

    private var hostError: String? {
        AppSettings.isValidHost(trimmedHost) ? nil : "Enter an IP address, such as 127.0.0.1 or ::1, or localhost."
    }

    private var isServerAtDefaults: Bool {
        let defaults = AppSettings()
        return trimmedHost == defaults.host && AppSettings.parsePort(portText) == defaults.port
    }

    private func commit(_ field: Field?) {
        switch field {
        case .host, .port: commitServer()
        case .maxMessageCount, .maxAgeInDays: commitRetention()
        case nil: break
        }
    }

    /// Saves and applies the host and port if both are valid and changed.
    private func commitServer() {
        let host = trimmedHost
        guard AppSettings.isValidHost(host), let port = AppSettings.parsePort(portText) else { return }
        hostText = host
        portText = String(port)
        guard host != settings.host || port != settings.port else { return }

        settings.host = host
        settings.port = port
        settings.save(to: userDefaults)
        Task { await model.applyServerAddress(host: host, port: port) }
    }

    private func restoreServerDefaults() {
        let defaults = AppSettings()
        hostText = defaults.host
        portText = String(defaults.port)
        commitServer()
    }

    // MARK: - Menu Bar

    /// Saves and applies the menu bar options. `hidesDockIcon` is kept as set even while the menu bar item is off, so
    /// turning the item back on restores the user's choice; the activation policy ignores it until then.
    private func commitMenuBar() {
        guard showsMenuBarItem != settings.showsMenuBarItem || hidesDockIcon != settings.hidesDockIcon else { return }
        settings.showsMenuBarItem = showsMenuBarItem
        settings.hidesDockIcon = hidesDockIcon
        settings.save(to: userDefaults)
        model.updateMenuBarSettings(showsMenuBarItem: showsMenuBarItem, hidesDockIcon: hidesDockIcon)
    }

    // MARK: - Retention

    /// Saves and applies the retention settings if they are valid and changed. When they would delete messages, asks
    /// first if `canAskToDelete`, or otherwise discards the change.
    private func commitRetention(canAskToDelete: Bool = true) {
        var updated = settings
        updated.limitsMessageCount = limitsMessageCount
        updated.limitsMessageAge = limitsMessageAge

        // A switched-off limit's field is disabled, so an invalid value there falls back to the saved one.
        if let count = AppSettings.parsePositiveInteger(maxMessageCountText) {
            updated.maxMessageCount = count
        } else if limitsMessageCount {
            return
        }
        if let days = AppSettings.parsePositiveInteger(maxAgeInDaysText) {
            updated.maxAgeInDays = days
        } else if limitsMessageAge {
            return
        }
        guard updated != settings else { return }

        let removedCount = updated.retentionPolicy.numberOfMessagesRemoved(
            receivedDates: model.summaries.map(\.receivedAt),
            now: .now
        )
        if removedCount == 0 {
            applyRetention(updated)
        } else if canAskToDelete {
            pendingRetention = PendingRetention(settings: updated, removedCount: removedCount)
        } else {
            resetRetentionDrafts()
        }
    }

    private func applyRetention(_ updated: AppSettings) {
        settings = updated
        settings.save(to: userDefaults)
        resetRetentionDrafts()
        Task { await model.updateRetentionPolicy(updated.retentionPolicy) }
    }

    private func deletionTitle(count: Int) -> String {
        count == 1 ? "Delete 1 Message?" : "Delete \(count) Messages?"
    }

    // MARK: - Drafts

    private func resetDrafts() {
        hostText = settings.host
        portText = String(settings.port)
        resetRetentionDrafts()
    }

    private func resetRetentionDrafts() {
        maxMessageCountText = String(settings.maxMessageCount)
        maxAgeInDaysText = String(settings.maxAgeInDays)
        limitsMessageCount = settings.limitsMessageCount
        limitsMessageAge = settings.limitsMessageAge
    }
}

// MARK: - General

extension SettingsView {
    private var generalSection: some View {
        Section {
            Toggle(
                "Open Dev Mail at login",
                isOn: Binding(get: { openAtLogin.isEnabled }, set: { openAtLogin.setEnabled($0) })
            )
            if let errorMessage = openAtLogin.errorMessage {
                validationMessage(errorMessage)
            }
            if openAtLogin.requiresApproval {
                LabeledContent {
                    Button("Open Login Items", action: openAtLogin.openSystemSettings)
                } label: {
                    Label(
                        "Allow Dev Mail in System Settings to open it at login.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("General")
        }
    }
}

// MARK: - Storage and Demo

extension SettingsView {
    private var storageSection: some View {
        Section("Storage") {
            LabeledContent {
                Button("Show in Finder", action: showMessagesFolder)
            } label: {
                Text("Messages Folder")
                Text((model.directory.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var demoSection: some View {
        Section {
            LabeledContent("Demo Messages") {
                Button("Import", action: importDemoMessages)
                    .disabled(isImportingDemoMessages)
            }
        } footer: {
            Text("Adds 10 sample HTML and plain-text messages, including Laravel mail.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func showMessagesFolder() {
        // The store creates the folder when it opens, but it may be missing if that failed or it was deleted since.
        try? FileManager.default.createDirectory(at: model.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([model.directory])
    }

    private func importDemoMessages() {
        isImportingDemoMessages = true
        Task {
            await model.importDemoMessages()
            isImportingDemoMessages = false
        }
    }
}

#Preview {
    // Never started, so the preview doesn't touch the disk or open a port.
    SettingsView(userDefaults: UserDefaults(suiteName: "DevMailPreview") ?? .standard)
        .environment(AppModel(directory: FileManager.default.temporaryDirectory))
}
