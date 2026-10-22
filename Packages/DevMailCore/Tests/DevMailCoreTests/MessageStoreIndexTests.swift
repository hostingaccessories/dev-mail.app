import Foundation
import Testing

@testable import DevMailCore

/// Persistence across reopening: index loading, rebuilding and reconciliation with the files on disk.
struct MessageStoreIndexTests {
    @Test func persistsMessagesAndReadStateAcrossReopen() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let first = StorageFixtures.message(subject: "First")
        let second = StorageFixtures.message(subject: "Second", receivedAt: StorageFixtures.referenceDate + 1)
        do {
            let store = try await MessageStore(directory: temp.messages)
            try await store.add(first)
            try await store.add(second)
            try await store.setRead(true, for: first.id)
        }

        let reopened = try await MessageStore(directory: temp.messages)

        let summaries = await reopened.summaries()
        #expect(summaries.map(\.subject) == ["Second", "First"])
        #expect(summaries.map(\.isRead) == [false, true])
    }

    @Test func rebuildsMissingIndexFromFiles() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let original = try await StorageFixtures.populatedStore(in: temp)
        let expected = await original.summaries()
        try FileManager.default.removeItem(at: temp.messages.appending(path: "index.json"))

        let rebuilt = try await MessageStore(directory: temp.messages)

        #expect(await rebuilt.summaries() == expected)
        #expect(FileManager.default.fileExists(atPath: temp.messages.appending(path: "index.json").path()))
    }

    @Test func rebuildsCorruptIndexFromFiles() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let original = try await StorageFixtures.populatedStore(in: temp)
        let expected = await original.summaries()
        try Data("{not json".utf8).write(to: temp.messages.appending(path: "index.json"))

        let rebuilt = try await MessageStore(directory: temp.messages)

        #expect(await rebuilt.summaries() == expected)
    }

    @Test func reconcilesIndexWithFilesOnOpen() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let kept = StorageFixtures.message(subject: "Kept")
        let vanished = StorageFixtures.message(subject: "Vanished", receivedAt: StorageFixtures.referenceDate + 1)
        try await store.add(kept)
        try await store.add(vanished)
        try FileManager.default.removeItem(at: try await store.fileURL(for: vanished.id))

        // A correctly named file dropped in by hand has no extended attributes and no index entry.
        let manualID = UUID()
        let manualURL = temp.messages.appending(path: "1750000000500-\(manualID.uuidString.lowercased()).eml")
        try Data("Subject: Manual\r\n\r\nHi\r\n".utf8).write(to: manualURL)

        let reopened = try await MessageStore(directory: temp.messages)

        let summaries = await reopened.summaries()
        #expect(Set(summaries.map(\.id)) == [kept.id, manualID])
        #expect(await reopened.summary(for: manualID)?.subject == "Manual")
        #expect(await reopened.summary(for: manualID)?.isRead == false)
    }

    @Test func usesValidIndexWithoutReparsingFiles() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let message = StorageFixtures.message(subject: "Indexed")
        try await store.add(message)
        try Data("Subject: Changed on disk\r\n\r\n".utf8).write(to: try await store.fileURL(for: message.id))

        let reopened = try await MessageStore(directory: temp.messages)

        #expect(await reopened.summary(for: message.id)?.subject == "Indexed")
    }

    @Test func toleratesUnreadableAndGarbageFiles() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        try FileManager.default.createDirectory(at: temp.messages, withIntermediateDirectories: true)
        let garbageID = UUID()
        let garbageURL = temp.messages.appending(path: "0000000000001-\(garbageID.uuidString.lowercased()).eml")
        try Data([0x00, 0xFF, 0xFE, 0x0D, 0x0A, 0x80]).write(to: garbageURL)
        let unreadableURL = temp.messages.appending(path: "0000000000002-\(UUID().uuidString.lowercased()).eml")
        try FileManager.default.createDirectory(at: unreadableURL, withIntermediateDirectories: false)
        try Data("ignored".utf8).write(to: temp.messages.appending(path: "notes.txt"))
        try Data("not-a-message".utf8).write(to: temp.messages.appending(path: "nonsense.eml"))
        let uppercaseName = "0000000000003-\(UUID().uuidString.uppercased()).eml"
        try Data("Subject: Ignored\r\n\r\n".utf8).write(to: temp.messages.appending(path: uppercaseName))

        let store = try await MessageStore(directory: temp.messages)

        #expect(await store.summaries().map(\.id) == [garbageID])
    }

    @Test func loadsThousandsOfMessagesQuickly() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        try FileManager.default.createDirectory(at: temp.messages, withIntermediateDirectories: true)
        for offset in 0..<1_500 {
            let message = StorageFixtures.message(subject: "Message \(offset)")
            let millis = 1_750_000_000_000 + offset
            try message.data.write(
                to: temp.messages.appending(path: "\(millis)-\(message.id.uuidString.lowercased()).eml")
            )
        }
        let rebuilt = try await MessageStore(directory: temp.messages, retentionPolicy: .unlimited)
        #expect(await rebuilt.summaries().count == 1_500)

        let clock = ContinuousClock()
        var reopenedCount = 0
        let elapsed = try await clock.measure {
            let reopened = try await MessageStore(directory: temp.messages, retentionPolicy: .unlimited)
            reopenedCount = await reopened.summaries().count
        }

        #expect(reopenedCount == 1_500)
        #expect(elapsed < .seconds(2))
    }
}
