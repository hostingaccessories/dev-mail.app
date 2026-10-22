import DevMailCore
import Foundation
import Testing

@testable import DevMail

struct MessageBodyModeTests {
    private let htmlOnly = ParsedMessage(htmlBody: "<p>Hi</p>")
    private let textOnly = ParsedMessage(textBody: "Hi")
    private let both = ParsedMessage(htmlBody: "<p>Hi</p>", textBody: "Hi")
    private let neither = ParsedMessage()

    @Test func availableModes() {
        #expect(MessageBodyMode.availableModes(for: htmlOnly) == [.html, .plainText, .source])
        #expect(MessageBodyMode.availableModes(for: both) == [.html, .plainText, .source])
        #expect(MessageBodyMode.availableModes(for: textOnly) == [.plainText, .source])
        #expect(MessageBodyMode.availableModes(for: neither) == [.plainText, .source])
    }

    @Test func defaultsToHTMLWhenPresent() {
        #expect(MessageBodyMode.resolved(preferred: nil, for: htmlOnly) == .html)
        #expect(MessageBodyMode.resolved(preferred: nil, for: both) == .html)
        #expect(MessageBodyMode.resolved(preferred: nil, for: textOnly) == .plainText)
        #expect(MessageBodyMode.resolved(preferred: nil, for: neither) == .plainText)
    }

    @Test func keepsPreferenceWhenSupported() {
        #expect(MessageBodyMode.resolved(preferred: .plainText, for: both) == .plainText)
        #expect(MessageBodyMode.resolved(preferred: .source, for: textOnly) == .source)
        #expect(MessageBodyMode.resolved(preferred: .html, for: both) == .html)
    }

    @Test func fallsBackWhenPreferenceUnsupported() {
        #expect(MessageBodyMode.resolved(preferred: .html, for: textOnly) == .plainText)
        #expect(MessageBodyMode.resolved(preferred: .html, for: neither) == .plainText)
    }
}

struct EnvelopeRecipientsTests {
    @Test func listsOnlyRecipientsMissingFromHeaders() {
        let message = ParsedMessage(
            to: [EmailAddress(name: "To", address: "to@example.com")],
            cc: [EmailAddress(address: "CC@example.com")],
            bcc: [EmailAddress(address: "bcc@example.com")]
        )
        let envelope = [
            "to@example.com", "cc@example.com", "<BCC@example.com>", "hidden@example.com", "hidden@example.com",
        ]

        #expect(EnvelopeRecipients.unlisted(envelope, in: message) == ["hidden@example.com"])
    }

    @Test func emptyEnvelope() {
        #expect(EnvelopeRecipients.unlisted([], in: ParsedMessage()).isEmpty)
    }
}
