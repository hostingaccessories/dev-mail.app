import Foundation

@testable import DevMailCore

/// A unique folder under the system temporary directory, removed by `cleanUp()`. Storage tests never touch the real
/// Application Support folder.
struct TemporaryDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appending(path: "DevMailCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// The messages folder inside the temporary directory; deliberately not created so the store must create it.
    var messages: URL { url.appending(path: "Messages", directoryHint: .isDirectory) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum StorageFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)

    static func message(
        subject: String = "Hello",
        from: String = "Sender <sender@example.com>",
        to toHeader: String = "Recipient <rcpt@example.com>",
        body: String = "Body text",
        envelopeRecipients: [String] = ["rcpt@example.com"],
        receivedAt: Date = referenceDate,
        extraHeaders: String = ""
    ) -> ReceivedMessage {
        let raw = """
            From: \(from)\r
            To: \(toHeader)\r
            Subject: \(subject)\r
            Date: Mon, 16 Jun 2025 10:00:00 +0000\r
            \(extraHeaders)Content-Type: text/plain; charset=utf-8\r
            \r
            \(body)\r

            """
        return ReceivedMessage(
            envelopeSender: "sender@example.com",
            recipients: envelopeRecipients,
            data: Data(raw.utf8),
            receivedAt: receivedAt
        )
    }

    static func posixPermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// A store with three messages, the second of them read and received at a sub-millisecond time.
    static func populatedStore(in temp: TemporaryDirectory) async throws -> MessageStore {
        let store = try await MessageStore(directory: temp.messages)
        let messages = [
            message(subject: "One", receivedAt: referenceDate),
            message(subject: "Two", receivedAt: referenceDate.addingTimeInterval(0.0015)),
            message(subject: "Three", envelopeRecipients: ["bcc@example.com"], receivedAt: referenceDate + 9),
        ]
        for message in messages {
            try await store.add(message)
        }
        try await store.setRead(true, for: messages[1].id)
        return store
    }

    static func emlFileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path()).filter { $0.hasSuffix(".eml") }
    }
}

/// A test failure with a message, for helpers that throw.
struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
