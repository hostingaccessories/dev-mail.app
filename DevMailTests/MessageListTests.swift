import DevMailCore
import Foundation
import Testing

@testable import DevMail

@MainActor
struct MessageListTests {
    // MARK: - Row presentation

    @Test func senderPrefersDisplayNameThenAddressThenEnvelope() {
        #expect(
            Self.summary(sender: EmailAddress(name: "Jane Doe", address: "jane@example.com")).senderDisplayName
                == "Jane Doe"
        )
        #expect(
            Self.summary(sender: EmailAddress(name: "  ", address: "jane@example.com")).senderDisplayName
                == "jane@example.com"
        )
        #expect(
            Self.summary(sender: nil, envelopeSender: "bounce@example.com").senderDisplayName
                == "bounce@example.com"
        )
        #expect(Self.summary(sender: nil, envelopeSender: nil).senderDisplayName == "(Unknown Sender)")
    }

    @Test func subjectFallsBackWhenMissingOrBlank() {
        #expect(Self.summary(subject: "Hello").displaySubject == "Hello")
        #expect(Self.summary(subject: nil).displaySubject == "(No Subject)")
        #expect(Self.summary(subject: " ").displaySubject == "(No Subject)")
    }

    @Test func showsTimeForTodayAndDateOtherwise() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let earlyToday = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 0)))
        let lateYesterday = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 23, minute: 59))
        )

        #expect(MessageDateStyle(for: earlyToday, now: now, calendar: calendar) == .time)
        #expect(MessageDateStyle(for: lateYesterday, now: now, calendar: calendar) == .date)
        #expect(MessageDateStyle(for: now.addingTimeInterval(86_400), now: now, calendar: calendar) == .date)
    }

    // MARK: - Selection

    @Test func selectsMessageBelowDeletedOnes() {
        let ids = (0..<5).map { _ in UUID() }
        #expect(MessageListSelection.neighbour(afterDeleting: [ids[1]], in: ids) == ids[2])
        #expect(MessageListSelection.neighbour(afterDeleting: [ids[1], ids[3]], in: ids) == ids[4])
    }

    @Test func selectsMessageAboveWhenDeletingTheLast() {
        let ids = (0..<4).map { _ in UUID() }
        #expect(MessageListSelection.neighbour(afterDeleting: [ids[2], ids[3]], in: ids) == ids[1])
    }

    @Test func selectsNothingWhenNothingRemains() {
        let ids = (0..<2).map { _ in UUID() }
        #expect(MessageListSelection.neighbour(afterDeleting: Set(ids), in: ids) == nil)
        #expect(MessageListSelection.neighbour(afterDeleting: [UUID()], in: ids) == nil)
        #expect(MessageListSelection.neighbour(afterDeleting: [UUID()], in: []) == nil)
    }

    @Test func readToggleMarksReadWhenAnyIsUnread() {
        let read = Self.summary(isRead: true)
        let unread = Self.summary(isRead: false)
        let summaries = [read, unread]
        #expect(MessageListSelection.shouldMarkRead([read.id, unread.id], in: summaries))
        #expect(!MessageListSelection.shouldMarkRead([read.id], in: summaries))
        #expect(!MessageListSelection.shouldMarkRead([], in: summaries))
    }

    // MARK: - Dock badge

    @Test func badgeLabelHidesAtZero() {
        #expect(DockBadgeController.badgeLabel(unreadCount: 0) == nil)
        #expect(DockBadgeController.badgeLabel(unreadCount: 3) == "3")
        #expect(DockBadgeController.badgeLabel(unreadCount: 1200) == "1200")
    }

    // MARK: - Model

    @Test(.timeLimit(.minutes(1))) func setsReadStateOfSeveralMessages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "DevMailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let directory = root.appending(path: "Messages", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await MessageStore(directory: directory)
        var ids: [UUID] = []
        for index in 1...3 {
            let raw = "From: a@example.com\r\nTo: b@example.com\r\nSubject: \(index)\r\n\r\nBody\r\n"
            let message = ReceivedMessage(
                envelopeSender: "a@example.com",
                recipients: ["b@example.com"],
                data: Data(raw.utf8),
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            ids.append(try await store.add(message).id)
        }

        let model = AppModel(directory: directory, configuration: SMTPServerConfiguration(port: 0))
        await model.start()

        await model.setRead(true, ids: [ids[0], ids[1], UUID()])
        try await waitUntil { model.unreadCount == 1 }

        await model.setRead(false, ids: Set(ids))
        try await waitUntil { model.unreadCount == 3 }
        #expect(model.lastError == nil)

        await model.shutdown()
    }

    // MARK: - Helpers

    private static func summary(
        sender: EmailAddress? = EmailAddress(address: "sender@example.com"),
        envelopeSender: String? = "sender@example.com",
        subject: String? = "Subject",
        isRead: Bool = false
    ) -> MessageSummary {
        MessageSummary(
            id: UUID(),
            sender: sender,
            recipients: ["rcpt@example.com"],
            envelopeSender: envelopeSender,
            envelopeRecipients: ["rcpt@example.com"],
            subject: subject,
            date: .now,
            receivedAt: .now,
            size: 0,
            snippet: "",
            hasAttachments: false,
            isRead: isRead
        )
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for condition")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
