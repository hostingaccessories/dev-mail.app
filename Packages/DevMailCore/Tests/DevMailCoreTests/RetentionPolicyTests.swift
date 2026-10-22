import Foundation
import Testing

@testable import DevMailCore

struct RetentionPolicyTests {
    private static let day: TimeInterval = 86_400

    @Test func defaultsToThousandMessagesAndNoAgeLimit() {
        let policy = RetentionPolicy()

        #expect(policy.maxMessageCount == 1_000)
        #expect(policy.maxAgeInDays == nil)
    }

    @Test func keepsNewestMessagesAfterEachAdd() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(
            directory: temp.messages,
            retentionPolicy: RetentionPolicy(maxMessageCount: 3)
        )

        for offset in 0..<5 {
            try await store.add(
                StorageFixtures.message(
                    subject: "Message \(offset)",
                    receivedAt: StorageFixtures.referenceDate + Double(offset)
                )
            )
        }

        #expect(await store.summaries().map(\.subject) == ["Message 4", "Message 3", "Message 2"])
        #expect(try StorageFixtures.emlFileNames(in: temp.messages).count == 3)
    }

    @Test func deletesMessagesOlderThanMaxAgeAfterAdd() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let now = StorageFixtures.referenceDate
        let store = try await MessageStore(
            directory: temp.messages,
            retentionPolicy: RetentionPolicy(maxMessageCount: nil, maxAgeInDays: 7),
            now: { now }
        )
        let old = StorageFixtures.message(subject: "Old", receivedAt: now - 8 * Self.day)
        let recent = StorageFixtures.message(subject: "Recent", receivedAt: now - 6 * Self.day)

        try await store.add(recent)
        try await store.add(old)

        #expect(await store.summaries().map(\.subject) == ["Recent"])
        #expect(try StorageFixtures.emlFileNames(in: temp.messages).count == 1)
    }

    @Test func appliesLimitsOnOpen() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let now = StorageFixtures.referenceDate
        do {
            let store = try await MessageStore(directory: temp.messages, retentionPolicy: .unlimited)
            for offset in 0..<4 {
                try await store.add(
                    StorageFixtures.message(subject: "Day \(offset)", receivedAt: now - Double(offset) * Self.day)
                )
            }
        }

        // Three days later, a 5-day age limit removes "Day 2" and "Day 3"; the count limit then keeps one.
        let later = now + 3 * Self.day + 1
        let byAge = try await MessageStore(
            directory: temp.messages,
            retentionPolicy: RetentionPolicy(maxMessageCount: nil, maxAgeInDays: 5),
            now: { later }
        )
        #expect(await byAge.summaries().map(\.subject) == ["Day 0", "Day 1"])

        let byCount = try await MessageStore(
            directory: temp.messages,
            retentionPolicy: RetentionPolicy(maxMessageCount: 1),
            now: { later }
        )
        #expect(await byCount.summaries().map(\.subject) == ["Day 0"])
        #expect(try StorageFixtures.emlFileNames(in: temp.messages).count == 1)
    }

    @Test func appliesUpdatedPolicyImmediately() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanUp() }
        let store = try await MessageStore(directory: temp.messages, retentionPolicy: .unlimited)
        for offset in 0..<4 {
            try await store.add(StorageFixtures.message(receivedAt: StorageFixtures.referenceDate + Double(offset)))
        }
        var changes = await store.changes().makeAsyncIterator()
        let oldest = await store.summaries().suffix(2).map(\.id)

        await store.updateRetentionPolicy(RetentionPolicy(maxMessageCount: 2))

        #expect(await store.retentionPolicy == RetentionPolicy(maxMessageCount: 2))
        #expect(await store.summaries().count == 2)
        #expect(await changes.next() == .removed(Set(oldest)))
        #expect(try StorageFixtures.emlFileNames(in: temp.messages).count == 2)
    }

    @Test func treatsNonPositiveLimitsAsOne() {
        let base = StorageFixtures.referenceDate
        let summaries = (0..<3).map { offset in
            MessageSummary(
                id: UUID(),
                sender: nil,
                recipients: [],
                envelopeSender: nil,
                envelopeRecipients: [],
                subject: nil,
                date: base,
                receivedAt: base - Double(offset) * Self.day * 2,
                size: 0,
                snippet: "",
                hasAttachments: false,
                isRead: false
            )
        }

        let expired = RetentionPolicy(maxMessageCount: 0, maxAgeInDays: -5)
            .expiredMessageIDs(in: summaries, now: base)

        #expect(expired == Set(summaries.dropFirst().map(\.id)))
    }
}
