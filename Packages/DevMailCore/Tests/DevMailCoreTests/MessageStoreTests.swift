import Foundation
import Testing

@testable import DevMailCore

struct MessageStoreTests {
    @Test func createsSecureFolderAndWritesRawBytes() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let message = StorageFixtures.message()

        try await store.add(message)

        let fileURL = try await store.fileURL(for: message.id)
        #expect(try StorageFixtures.posixPermissions(of: temp.messages) == 0o700)
        #expect(try StorageFixtures.posixPermissions(of: fileURL) == 0o600)
        #expect(try Data(contentsOf: fileURL) == message.data)
        #expect(try await store.rawData(for: message.id) == message.data)
        #expect(fileURL.lastPathComponent == "1750000000000-\(message.id.uuidString.lowercased()).eml")

        let indexURL = temp.messages.appending(path: "index.json")
        #expect(try StorageFixtures.posixPermissions(of: indexURL) == 0o600)
    }

    @Test func tightensPermissionsOfExistingFolder() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        try FileManager.default.createDirectory(
            at: temp.messages,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        _ = try await MessageStore(directory: temp.messages)

        #expect(try StorageFixtures.posixPermissions(of: temp.messages) == 0o700)
    }

    @Test func indexesSummaryFields() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let message = StorageFixtures.message(
            to: "Recipient <rcpt@example.com>",
            body: "Reset your   password",
            extraHeaders: "Cc: copy@example.com\r\n"
        )

        let summary = try await store.add(message)

        #expect(summary.id == message.id)
        #expect(summary.sender == EmailAddress(name: "Sender", address: "sender@example.com"))
        #expect(summary.recipients == ["Recipient <rcpt@example.com>", "copy@example.com"])
        #expect(summary.envelopeSender == "sender@example.com")
        #expect(summary.envelopeRecipients == ["rcpt@example.com"])
        #expect(summary.subject == "Hello")
        #expect(summary.date == Date(timeIntervalSince1970: 1_750_068_000))
        #expect(summary.receivedAt == StorageFixtures.referenceDate)
        #expect(summary.size == message.data.count)
        #expect(summary.snippet == "Reset your password")
        #expect(!summary.hasAttachments)
        #expect(!summary.isRead)
        #expect(await store.summaries() == [summary])
    }

    @Test func fallsBackToEnvelopeWhenHeadersAreMissing() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let message = ReceivedMessage(
            envelopeSender: "bounce@example.com",
            recipients: ["hidden@example.com"],
            data: Data("Subject: No addresses\r\n\r\nHi\r\n".utf8),
            receivedAt: StorageFixtures.referenceDate
        )

        let summary = try await store.add(message)

        #expect(summary.sender == EmailAddress(address: "bounce@example.com"))
        #expect(summary.recipients == ["hidden@example.com"])
        #expect(summary.date == StorageFixtures.referenceDate)
    }

    @Test func listsNewestFirst() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let base = StorageFixtures.referenceDate
        let middle = StorageFixtures.message(subject: "Middle", receivedAt: base.addingTimeInterval(60))
        let oldest = StorageFixtures.message(subject: "Oldest", receivedAt: base)
        let newest = StorageFixtures.message(subject: "Newest", receivedAt: base.addingTimeInterval(120))

        for message in [middle, oldest, newest] {
            try await store.add(message)
        }

        #expect(await store.summaries().map(\.subject) == ["Newest", "Middle", "Oldest"])
    }

    @Test func searchesSubjectSenderAndRecipients() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let base = StorageFixtures.referenceDate
        try await store.add(StorageFixtures.message(subject: "Café receipt", receivedAt: base))
        try await store.add(
            StorageFixtures.message(subject: "Welcome", from: "Zoë <zoe@shop.test>", receivedAt: base + 1)
        )
        try await store.add(
            StorageFixtures.message(
                subject: "Invoice",
                to: "billing@example.org",
                envelopeRecipients: ["secret-bcc@example.net"],
                receivedAt: base + 2
            )
        )

        #expect(await store.summaries(matching: "CAFE").map(\.subject) == ["Café receipt"])
        #expect(await store.summaries(matching: "zoe").map(\.subject) == ["Welcome"])
        #expect(await store.summaries(matching: "BILLING@").map(\.subject) == ["Invoice"])
        #expect(await store.summaries(matching: "secret-bcc").map(\.subject) == ["Invoice"])
        #expect(await store.summaries(matching: "  ").count == 3)
        #expect(await store.summaries(matching: "nothing").isEmpty)
    }

    @Test func parsesStoredMessage() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let message = StorageFixtures.message(subject: "Parsed")
        try await store.add(message)

        let parsed = try await store.parsedMessage(for: message.id)

        #expect(parsed.subject == "Parsed")
        #expect(parsed.textBody == "Body text\n")
    }

    @Test func marksReadAndUnread() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let message = StorageFixtures.message()
        try await store.add(message)

        try await store.setRead(true, for: message.id)
        #expect(await store.summary(for: message.id)?.isRead == true)
        try await store.setRead(false, for: message.id)
        #expect(await store.summary(for: message.id)?.isRead == false)
    }

    @Test func deletesSelectedAndAllMessages() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await StorageFixtures.populatedStore(in: temp)
        let ids = await store.summaries().map(\.id)
        let firstURL = try await store.fileURL(for: ids[0])

        try await store.delete(ids: [ids[0], UUID()])

        #expect(await store.summaries().map(\.id) == Array(ids.dropFirst()))
        #expect(!FileManager.default.fileExists(atPath: firstURL.path()))

        try await store.deleteAll()

        #expect(await store.summaries().isEmpty)
        #expect(try StorageFixtures.emlFileNames(in: temp.messages).isEmpty)
        #expect(try await MessageStore(directory: temp.messages).summaries().isEmpty)
    }

    @Test func throwsTypedErrorsForUnknownMessages() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let id = UUID()

        await #expect(throws: MessageStoreError.messageNotFound(id)) { try await store.rawData(for: id) }
        await #expect(throws: MessageStoreError.messageNotFound(id)) { try await store.setRead(true, for: id) }
        await #expect(throws: MessageStoreError.messageNotFound(id)) { try await store.fileURL(for: id) }
    }

    @Test func rejectsDuplicateMessages() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        let message = StorageFixtures.message()
        try await store.add(message)

        await #expect(throws: MessageStoreError.duplicateMessage(message.id)) { try await store.add(message) }
    }

    @Test func publishesChanges() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages)
        var changes = await store.changes().makeAsyncIterator()
        let message = StorageFixtures.message()

        let added = try await store.add(message)
        try await store.setRead(true, for: message.id)
        try await store.delete(ids: [message.id])

        var read = added
        read.isRead = true
        #expect(await changes.next() == .added(added))
        #expect(await changes.next() == .updated(read))
        #expect(await changes.next() == .removed([message.id]))
    }
}
