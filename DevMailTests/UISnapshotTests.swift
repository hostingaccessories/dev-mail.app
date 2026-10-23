import AppKit
import DevMailCore
import Foundation
import SwiftUI
import Testing

@testable import DevMail

/// Where `UISnapshotTests` writes PNGs; set by `make snapshots`.
private let snapshotOutputDirectory: URL? = ProcessInfo.processInfo.environment["DEVMAIL_SNAPSHOTS_DIR"]
    .flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }

/// Renders the app's windows from fixture data into PNGs, so the UI can be checked by eye without screen recording
/// or Accessibility permissions. Windows are drawn offscreen inside the test process; nothing else on screen is
/// captured.
///
/// Opt-in: runs only when `DEVMAIL_SNAPSHOTS_DIR` is set, which `make snapshots` does. Uses fixture messages only,
/// never the real messages folder.
@MainActor
@Suite(.enabled(if: snapshotOutputDirectory != nil), .timeLimit(.minutes(2)), .serialized)
struct UISnapshotTests {
    private static let windowSize = CGSize(width: 1100, height: 720)

    @Test(arguments: SnapshotAppearance.allCases)
    func emptyMailbox(appearance: SnapshotAppearance) async throws {
        try await withFixture(messages: []) { fixture in
            try await snapshot("main-empty", appearance: appearance, size: Self.windowSize) {
                ContentView().environment(fixture.model)
            }
        }
    }

    @Test(arguments: SnapshotAppearance.allCases)
    func messageList(appearance: SnapshotAppearance) async throws {
        try await withFixture { fixture in
            try await snapshot("main-list", appearance: appearance, size: Self.windowSize) {
                ContentView().environment(fixture.model)
            }
        }
    }

    /// The list on its own, outside the split view: in the full window the sidebar is Liquid Glass, which an
    /// offscreen render can't draw reliably.
    @Test(arguments: SnapshotAppearance.allCases)
    func messageListRows(appearance: SnapshotAppearance) async throws {
        try await withFixture { fixture in
            let id = try fixture.id(of: SnapshotFixtures.textSubject)
            try await snapshot("list", appearance: appearance, size: CGSize(width: 320, height: 520), toolbar: false) {
                MessageListView(selection: .constant([id])).environment(fixture.model)
            }
        }
    }

    @Test(arguments: SnapshotAppearance.allCases)
    func htmlMessage(appearance: SnapshotAppearance) async throws {
        try await withFixture { fixture in
            let id = try fixture.id(of: SnapshotFixtures.htmlSubject)
            try await snapshot("detail-html", appearance: appearance, size: Self.windowSize) {
                ContentView(selection: [id]).environment(fixture.model)
            }
        }
    }

    @Test(arguments: SnapshotAppearance.allCases)
    func plainTextMessage(appearance: SnapshotAppearance) async throws {
        try await withFixture { fixture in
            let id = try fixture.id(of: SnapshotFixtures.textSubject)
            try await snapshot("detail-text", appearance: appearance, size: Self.windowSize) {
                ContentView(selection: [id]).environment(fixture.model)
            }
        }
    }

    /// The headers list on its own, for the same reason as `messageListRows`.
    @Test(arguments: SnapshotAppearance.allCases)
    func headersInspector(appearance: SnapshotAppearance) async throws {
        try await withFixture { fixture in
            let message = try await fixture.model.parsedMessage(for: fixture.id(of: SnapshotFixtures.htmlSubject))
            try await snapshot(
                "headers-inspector",
                appearance: appearance,
                size: CGSize(width: 320, height: 520),
                toolbar: false
            ) {
                HeadersInspector(headers: message.headers)
            }
        }
    }

    @Test(arguments: SnapshotAppearance.allCases)
    func settings(appearance: SnapshotAppearance) async throws {
        try await withFixture(messages: []) { fixture in
            let suiteName = "DevMailSnapshots-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            try await snapshot("settings", appearance: appearance, size: CGSize(width: 500, height: 800)) {
                SettingsView(userDefaults: defaults).environment(fixture.model)
            }
        }
    }

    // MARK: - Helpers

    private func snapshot(
        _ name: String,
        appearance: SnapshotAppearance,
        size: CGSize,
        toolbar: Bool = true,
        @ViewBuilder content: () -> some View
    ) async throws {
        let directory = try #require(snapshotOutputDirectory)
        let png = try await OffscreenWindowRenderer.png(
            of: content(),
            size: size,
            appearance: appearance.appearance,
            toolbar: toolbar
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appending(path: "\(name)-\(appearance.rawValue).png"))
    }

    /// Runs `body` with a model backed by a temporary store holding `messages`, and always tears it down.
    private func withFixture(
        messages: [ReceivedMessage] = SnapshotFixtures.messages(),
        _ body: (SnapshotFixture) async throws -> Void
    ) async throws {
        let fixture = try await SnapshotFixture(messages: messages)
        do {
            try await body(fixture)
        } catch {
            await fixture.tearDown()
            throw error
        }
        await fixture.tearDown()
    }
}

enum SnapshotAppearance: String, CaseIterable, Sendable {
    case light, dark

    @MainActor var appearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// A started model (store plus a server on an ephemeral loopback port) in a unique temporary folder.
@MainActor
private struct SnapshotFixture {
    let root: URL
    let model: AppModel

    init(messages: [ReceivedMessage]) async throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DevMailSnapshots-\(UUID().uuidString)", directoryHint: .isDirectory)
        let directory = root.appending(path: "Messages", directoryHint: .isDirectory)
        let store = try await MessageStore(directory: directory)
        for message in messages {
            try await store.add(message)
        }
        model = AppModel(directory: directory, configuration: SMTPServerConfiguration(port: 0))
        await model.start()
        if let read = model.summaries.first(where: { $0.subject == SnapshotFixtures.readSubject }) {
            await model.markRead(read.id, isRead: true)
        }
    }

    func id(of subject: String) throws -> UUID {
        guard let summary = model.summaries.first(where: { $0.subject == subject }) else {
            throw SnapshotError("No fixture message with subject \(subject)")
        }
        return summary.id
    }

    func tearDown() async {
        await model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
