import Foundation
import Testing

@testable import DevMailCore

struct MessageComposerTests {
    private let date = Date(timeIntervalSince1970: 1_792_929_600)

    @Test func composesPlainTextMessage() throws {
        let longLine = String(repeating: "ünïcode ", count: 20) + "end "
        let message = OutgoingMessage(
            from: EmailAddress(name: "Dev Mail", address: "app@example.test"),
            to: [
                EmailAddress(name: "Jane, Q.", address: "jane@example.test"), EmailAddress(address: "bob@example.test"),
            ],
            cc: [EmailAddress(name: "Zoë", address: "zoe@example.test")],
            bcc: [EmailAddress(address: "secret@example.test")],
            subject: "Héllo — a subject long enough to need more than one encoded word in the header, surely",
            textBody: "Line one\n.leading dot\n\(longLine)\nx = y\n",
            extraHeaders: [MessageHeader(name: "X-Campaign", value: "launch")],
            date: date,
            messageID: "abc@example.test"
        )
        let data = try MessageComposer.compose(message)
        let source = try #require(String(bytes: data, encoding: .ascii))

        // 7-bit, CRLF only, short lines, and no trace of the Bcc recipient.
        #expect(!source.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(source.components(separatedBy: "\r\n").allSatisfy { $0.count <= 78 })
        #expect(!source.contains("secret@"))
        #expect(!source.lowercased().contains("bcc"))

        let parsed = MIMEParser.parse(data)
        #expect(parsed.from == [EmailAddress(name: "Dev Mail", address: "app@example.test")])
        #expect(parsed.to == message.to)
        #expect(parsed.cc == message.cc)
        #expect(parsed.subject == message.subject)
        #expect(parsed.date == date)
        #expect(parsed.messageID == "abc@example.test")
        #expect(parsed.headerValue(named: "X-Campaign") == "launch")
        #expect(parsed.textBody == "Line one\n.leading dot\n\(longLine)\nx = y\n")
        #expect(parsed.htmlBody == nil)
        #expect(
            message.envelopeRecipients == [
                "jane@example.test", "bob@example.test", "zoe@example.test", "secret@example.test",
            ]
        )
    }

    @Test func composesAlternativeBodiesWithAttachments() throws {
        let message = OutgoingMessage(
            from: EmailAddress(address: "app@example.test"),
            to: [EmailAddress(address: "jane@example.test")],
            textBody: "Text",
            htmlBody: "<p>HTML &amp; more</p>",
            attachments: [
                OutgoingAttachment(filename: "Reçu détaillé.csv", mimeType: "text/csv", data: Data("a,b\n".utf8)),
                OutgoingAttachment(
                    filename: "image \"1\".png",
                    mimeType: "image/png",
                    data: Data(repeating: 0xFF, count: 300)
                ),
            ]
        )
        let parsed = MIMEParser.parse(try MessageComposer.compose(message))
        #expect(parsed.textBody == "Text")
        #expect(parsed.htmlBody == "<p>HTML &amp; more</p>")
        #expect(parsed.attachments.map(\.filename) == ["Reçu détaillé.csv", "image \"1\".png"])
        #expect(parsed.attachments.map(\.mimeType) == ["text/csv", "image/png"])
        #expect(parsed.attachments.map(\.data) == message.attachments.map(\.data))
        #expect(parsed.subject == nil)
    }

    @Test func composesEmptyMessage() throws {
        let message = OutgoingMessage(
            from: EmailAddress(address: "app@example.test"),
            bcc: [EmailAddress(address: "x@y.z")]
        )
        let parsed = MIMEParser.parse(try MessageComposer.compose(message))
        #expect(parsed.to.isEmpty)
        #expect(parsed.textBody == "")
        #expect(parsed.messageID?.hasSuffix("@example.test") == true)
    }

    @Test func readsAttachmentTypeFromExtension() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "DevMailCoreTests-\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = try OutgoingAttachment(contentsOf: url)
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.filename == url.lastPathComponent)
    }

    @Test(arguments: [
        (EmailAddress(address: "not an address"), MessageComposerError.invalidAddress("not an address")),
        (EmailAddress(address: "a@b>\r\nRCPT TO:<c@d"), .invalidAddress("a@b>\r\nRCPT TO:<c@d")),
        (EmailAddress(address: "@example.test"), .invalidAddress("@example.test")),
        (EmailAddress(name: "Evil\r\nBcc: x", address: "a@b.c"), .invalidAddress("a@b.c")),
    ])
    func rejectsInvalidAddresses(address: EmailAddress, error: MessageComposerError) {
        let message = OutgoingMessage(from: EmailAddress(address: "app@example.test"), to: [address])
        #expect(throws: error) { try MessageComposer.compose(message) }
    }

    @Test(arguments: [
        (
            MessageHeader(name: "X-Test", value: "a\r\nBcc: x@y.z"),
            MessageComposerError.invalidHeaderValue(name: "X-Test")
        ),
        (MessageHeader(name: "Bad Name", value: "v"), .invalidHeaderName("Bad Name")),
        (MessageHeader(name: "", value: "v"), .invalidHeaderName("")),
        (MessageHeader(name: "content-type", value: "text/html"), .reservedHeader("content-type")),
        (MessageHeader(name: "Subject", value: "x"), .reservedHeader("Subject")),
    ])
    func rejectsInvalidHeaders(header: MessageHeader, error: MessageComposerError) {
        let message = OutgoingMessage(
            from: EmailAddress(address: "app@example.test"),
            to: [EmailAddress(address: "jane@example.test")],
            extraHeaders: [header]
        )
        #expect(throws: error) { try MessageComposer.compose(message) }
    }

    @Test func encodesQuotedPrintable() {
        #expect(MessageComposer.quotedPrintable("a=b") == "a=3Db")
        #expect(MessageComposer.quotedPrintable("trailing \nnext") == "trailing=20\r\nnext")
        #expect(MessageComposer.quotedPrintable("é") == "=C3=A9")

        let long = MessageComposer.quotedPrintable(String(repeating: "x", count: 100))
        #expect(long == String(repeating: "x", count: 75) + "=\r\n" + String(repeating: "x", count: 25))
    }

    @Test func quotesDisplayNames() {
        #expect(MessageComposer.encode(EmailAddress(name: "Jane Doe", address: "j@x.y")) == "Jane Doe <j@x.y>")
        #expect(
            MessageComposer.encode(EmailAddress(name: "Doe, \"J\"", address: "j@x.y")) == "\"Doe, \\\"J\\\"\" <j@x.y>"
        )
        #expect(MessageComposer.encode(EmailAddress(name: "Zoë", address: "z@x.y")) == "=?utf-8?B?Wm/Dqw==?= <z@x.y>")
        #expect(MessageComposer.encode(EmailAddress(address: "z@x.y")) == "z@x.y")
    }
}
