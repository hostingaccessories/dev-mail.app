import DevMailCore
import Foundation
import Testing

@testable import DevMail

@MainActor
struct DemoMessagesTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func loadsBundledMessagesNewestFirst() throws {
        let messages = try DemoMessages.messages(now: now)

        #expect(messages.count == 10)
        #expect(messages.first?.receivedAt == now)
        #expect(messages.map(\.receivedAt) == messages.map(\.receivedAt).sorted(by: >))
    }

    @Test func messagesParseWithAMixOfHTMLAndPlainText() throws {
        let messages = try DemoMessages.messages(now: now)
        let parsed = messages.map { MIMEParser.parse($0.data) }

        for (message, received) in zip(parsed, messages) {
            #expect(message.subject?.isEmpty == false)
            #expect(!message.from.isEmpty)
            #expect(message.date == received.receivedAt)
            #expect(message.htmlBody != nil || message.textBody?.isEmpty == false)
        }
        #expect(parsed.count { $0.htmlBody != nil } >= 4)
        #expect(parsed.count { $0.htmlBody == nil } >= 4)
        #expect(parsed.contains { $0.headerValue(named: "X-Laravel-Mailable") != nil })
        #expect(parsed.contains { !$0.attachments.isEmpty })
        #expect(parsed.contains { !$0.inlineParts.isEmpty })
    }

    @Test func messagesUseCRLFLineEndings() throws {
        for message in try DemoMessages.messages(now: now) {
            let text = try #require(String(bytes: message.data, encoding: .utf8))
            #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains(where: { $0 == "\r" || $0 == "\n" }))
        }
    }

    @Test func missingResourcesThrow() {
        #expect(throws: DemoMessagesError.self) {
            try DemoMessages.messages(bundle: Bundle(for: BundleToken.self))
        }
    }
}

/// Locates the test bundle, which has no demo messages.
private final class BundleToken {}
