import Foundation
import Testing

@testable import DevMailCore

struct SMTPSessionTests {
    // MARK: - Helpers

    private static func makeSession(
        maxMessageSize: Int = 1024,
        maxCommandLineLength: Int = 128
    ) -> SMTPSession {
        SMTPSession(
            configuration: SMTPServerConfiguration(
                maxMessageSize: maxMessageSize,
                maxCommandLineLength: maxCommandLineLength
            )
        )
    }

    private static func greetedSession(maxMessageSize: Int = 1024, maxCommandLineLength: Int = 128) -> SMTPSession {
        var session = makeSession(maxMessageSize: maxMessageSize, maxCommandLineLength: maxCommandLineLength)
        _ = session.receive(Data("EHLO client.test\r\n".utf8))
        return session
    }

    /// Sends one or more CRLF-terminated lines and returns the reply codes.
    private static func codes(_ session: inout SMTPSession, _ lines: String...) -> [Int] {
        replies(session.receive(Data(lines.map { $0 + "\r\n" }.joined().utf8))).map(\.code)
    }

    private static func replies(_ events: [SMTPSession.Event]) -> [SMTPReply] {
        events.compactMap { event in
            if case .reply(let reply) = event { reply } else { nil }
        }
    }

    private static func messages(_ events: [SMTPSession.Event]) -> [ReceivedMessage] {
        events.compactMap { event in
            if case .deliver(let message) = event { message } else { nil }
        }
    }

    // MARK: - Command flow

    @Test func greetingIsServiceReady() {
        let session = Self.makeSession()
        #expect(session.greeting.code == 220)
    }

    @Test func ehloAdvertisesExtensionsWithoutStartTLS() {
        var session = Self.makeSession(maxMessageSize: 2048)
        let reply = Self.replies(session.receive(Data("EHLO client.test\r\n".utf8))).first

        #expect(reply?.code == 250)
        #expect(reply?.lines.dropFirst() == ["SIZE 2048", "8BITMIME", "PIPELINING", "AUTH PLAIN LOGIN"])
        #expect(reply?.wireFormat.contains("STARTTLS") == false)
        #expect(reply?.wireFormat.hasSuffix("250 AUTH PLAIN LOGIN\r\n") == true)
    }

    @Test func heloAndEhloRequireHostname() {
        var session = Self.makeSession()
        #expect(Self.codes(&session, "HELO", "EHLO", "HELO client.test") == [501, 501, 250])
    }

    @Test func deliversMessageWithEnvelope() {
        var session = Self.greetedSession()
        let input = """
            MAIL FROM:<sender@example.com> BODY=8BITMIME\r
            RCPT TO:<one@example.com>\r
            RCPT TO:<two@example.com>\r
            DATA\r
            Subject: Hi\r
            \r
            Hello\r
            .\r

            """
        let events = session.receive(Data(input.utf8))

        #expect(Self.replies(events).map(\.code) == [250, 250, 250, 354, 250])
        let message = Self.messages(events).first
        #expect(message?.envelopeSender == "sender@example.com")
        #expect(message?.recipients == ["one@example.com", "two@example.com"])
        #expect(message?.data == Data("Subject: Hi\r\n\r\nHello\r\n".utf8))
    }

    @Test func deliverEventComesBeforeAcceptedReply() {
        var session = Self.greetedSession()
        let events = session.receive(Data("MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\nx\r\n.\r\n".utf8))

        guard events.count >= 2 else {
            Issue.record("Expected deliver and reply events")
            return
        }
        guard case .deliver = events[events.count - 2], case .reply(let reply) = events[events.count - 1] else {
            Issue.record("Expected deliver followed by reply, got \(events)")
            return
        }
        #expect(reply.code == 250)
    }

    @Test func nullSenderIsAccepted() {
        var session = Self.greetedSession()
        let events = session.receive(Data("MAIL FROM:<>\r\nRCPT TO:<a@b>\r\nDATA\r\nx\r\n.\r\n".utf8))

        #expect(Self.messages(events).count == 1)
        #expect(Self.messages(events).first?.envelopeSender == nil)
    }

    @Test func acceptsAddressesWithoutAngleBracketsAndSpaceAfterColon() {
        var session = Self.greetedSession()
        let events = session.receive(Data("MAIL FROM: a@b\r\nRCPT TO: c@d\r\nDATA\r\nx\r\n.\r\n".utf8))
        let message = Self.messages(events).first

        #expect(message?.envelopeSender == "a@b")
        #expect(message?.recipients == ["c@d"])
    }

    @Test func handlesInputSplitAcrossChunks() {
        var session = Self.greetedSession()
        var events: [SMTPSession.Event] = []
        for byte in "MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\nbody\r\n.\r\n".utf8 {
            events += session.receive(Data([byte]))
        }

        #expect(Self.replies(events).map(\.code) == [250, 250, 354, 250])
        #expect(Self.messages(events).first?.data == Data("body\r\n".utf8))
    }

    @Test func acceptsMultipleMessagesPerConnection() {
        var session = Self.greetedSession()
        let transaction = "MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\nx\r\n.\r\n"
        let events = session.receive(Data((transaction + transaction).utf8))

        #expect(Self.messages(events).count == 2)
    }

    @Test func simpleCommands() {
        var session = Self.greetedSession()
        #expect(Self.codes(&session, "NOOP", "RSET", "VRFY someone", "VRFY") == [250, 250, 252, 501])
    }

    @Test func rsetClearsTransaction() {
        var session = Self.greetedSession()
        #expect(Self.codes(&session, "MAIL FROM:<a@b>", "RSET", "RCPT TO:<c@d>") == [250, 250, 503])
    }

    @Test func quitClosesSession() {
        var session = Self.greetedSession()
        let events = session.receive(Data("QUIT\r\nNOOP\r\n".utf8))

        #expect(events == [.reply(SMTPReply(221, "Bye")), .close])
        #expect(session.isClosed)
        #expect(session.receive(Data("NOOP\r\n".utf8)).isEmpty)
    }

    @Test func commandsAreCaseInsensitive() {
        var session = Self.makeSession()
        #expect(
            Self.codes(&session, "ehlo client", "mail from:<a@b>", "rcpt to:<c@d>", "noop") == [250, 250, 250, 250]
        )
    }

    @Test func acceptsBareLineFeeds() {
        var session = Self.greetedSession()
        let events = session.receive(Data("MAIL FROM:<a@b>\nRCPT TO:<c@d>\nDATA\nline\n.\n".utf8))

        #expect(Self.messages(events).first?.data == Data("line\r\n".utf8))
    }

    // MARK: - Ordering and syntax errors

    @Test func mailRequiresGreeting() {
        var session = Self.makeSession()
        #expect(Self.codes(&session, "MAIL FROM:<a@b>") == [503])
    }

    @Test func rcptRequiresMail() {
        var session = Self.greetedSession()
        #expect(Self.codes(&session, "RCPT TO:<a@b>") == [503])
    }

    @Test func dataRequiresMailAndRecipient() {
        var session = Self.greetedSession()
        #expect(Self.codes(&session, "DATA", "MAIL FROM:<a@b>", "DATA") == [503, 250, 503])
    }

    @Test func nestedMailIsRejected() {
        var session = Self.greetedSession()
        #expect(Self.codes(&session, "MAIL FROM:<a@b>", "MAIL FROM:<c@d>") == [250, 503])
    }

    @Test func malformedPathsAreSyntaxErrors() {
        var session = Self.greetedSession()
        let codes = Self.codes(&session, "MAIL", "MAIL TO:<a@b>", "MAIL FROM:<a@b", "MAIL FROM:<a@b>", "RCPT TO:<>")
        #expect(codes == [501, 501, 501, 250, 501])
    }

    @Test func dataWithArgumentIsSyntaxError() {
        var session = Self.greetedSession()
        #expect(Self.codes(&session, "MAIL FROM:<a@b>", "RCPT TO:<c@d>", "DATA now") == [250, 250, 501])
    }

    @Test func unknownCommands() {
        var session = Self.greetedSession()
        #expect(Self.codes(&session, "FOO bar", "", "STARTTLS", "EXPN list", "HELP") == [500, 500, 502, 502, 502])
    }

    @Test func tooManyRecipients() {
        var session = Self.greetedSession()
        var input = "MAIL FROM:<a@b>\r\n"
        for index in 0...SMTPSession.maxRecipients {
            input += "RCPT TO:<user\(index)@example.com>\r\n"
        }
        let codes = Self.replies(session.receive(Data(input.utf8))).map(\.code)

        #expect(codes.last == 452)
        #expect(codes.filter { $0 == 250 }.count == SMTPSession.maxRecipients + 1)
    }

    // MARK: - Dot-unstuffing

    @Test func undoesDotStuffing() {
        var session = Self.greetedSession()
        let input = "MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\n..\r\n..leading dot\r\n...\r\nmid.dle\r\n.\r\n"
        let message = Self.messages(session.receive(Data(input.utf8))).first

        #expect(message?.data == Data(".\r\n.leading dot\r\n..\r\nmid.dle\r\n".utf8))
    }

    @Test func emptyMessageIsDelivered() {
        var session = Self.greetedSession()
        let message = Self.messages(session.receive(Data("MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\n.\r\n".utf8)))
            .first

        #expect(message?.data == Data())
    }

    @Test func preservesEightBitContent() {
        var session = Self.greetedSession()
        let body: [UInt8] = [0xC3, 0xA9, 0xFF, 0x00, 0x41]
        var input = Data("MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\n".utf8)
        input.append(contentsOf: body)
        input.append(Data("\r\n.\r\n".utf8))
        let message = Self.messages(session.receive(input)).first

        #expect(message?.data == Data(body + [0x0D, 0x0A]))
    }

}

// MARK: - Size limits

extension SMTPSessionTests {

    @Test func rejectsDeclaredSizeOverLimit() {
        var session = Self.greetedSession(maxMessageSize: 100)
        #expect(Self.codes(&session, "MAIL FROM:<a@b> SIZE=101", "MAIL FROM:<a@b> SIZE=100") == [552, 250])
    }

    @Test func rejectsMessageOverLimitAfterTerminator() {
        var session = Self.greetedSession(maxMessageSize: 10)
        let input = "MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\n0123456789\r\nmore\r\n.\r\nNOOP\r\n"
        let events = session.receive(Data(input.utf8))

        #expect(Self.messages(events).isEmpty)
        #expect(Self.replies(events).map(\.code) == [250, 250, 354, 552, 250])
    }

    @Test func messageExactlyAtLimitIsAccepted() {
        var session = Self.greetedSession(maxMessageSize: 10)
        let input = "MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\n01234567\r\n.\r\n"
        let message = Self.messages(session.receive(Data(input.utf8))).first

        #expect(message?.data.count == 10)
    }

    @Test func discardsUnterminatedLineOverMessageLimit() {
        var session = Self.greetedSession(maxMessageSize: 100)
        var events = session.receive(Data("MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\n".utf8))
        // A huge line without a line feed, then its end, which must not be mistaken for a terminator.
        events += session.receive(Data(repeating: UInt8(ascii: "x"), count: 500))
        events += session.receive(Data(".\r\nstill data\r\n".utf8))
        #expect(Self.replies(events).map(\.code) == [250, 250, 354])

        events = session.receive(Data(".\r\n".utf8))
        #expect(Self.replies(events).map(\.code) == [552])
        #expect(!session.isClosed)
    }

    @Test func commandLineOverLimitClosesSession() {
        var session = Self.greetedSession(maxCommandLineLength: 16)
        let events = session.receive(Data("NOOP \(String(repeating: "x", count: 20))\r\n".utf8))

        #expect(events == [.reply(SMTPReply(500, "Line too long")), .close])
        #expect(session.isClosed)
    }

    @Test func unterminatedCommandLineOverLimitClosesSession() {
        var session = Self.greetedSession(maxCommandLineLength: 16)
        let events = session.receive(Data(repeating: UInt8(ascii: "x"), count: 100))

        #expect(Self.replies(events).map(\.code) == [500])
        #expect(session.isClosed)
    }

    @Test func messageContentLinesMayExceedCommandLineLimit() {
        var session = Self.greetedSession(maxMessageSize: 1024, maxCommandLineLength: 16)
        let longLine = String(repeating: "y", count: 200)
        let input = "MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\n\(longLine)\r\n.\r\n"
        let message = Self.messages(session.receive(Data(input.utf8))).first

        #expect(message?.data == Data("\(longLine)\r\n".utf8))
    }

}

// MARK: - AUTH

extension SMTPSessionTests {

    @Test func authPlainWithInitialResponse() {
        var session = Self.greetedSession()
        let credentials = Data("\u{0}user\u{0}secret".utf8).base64EncodedString()
        #expect(Self.codes(&session, "AUTH PLAIN \(credentials)", "MAIL FROM:<a@b>") == [235, 250])
    }

    @Test func authPlainWithContinuation() {
        var session = Self.greetedSession()
        let credentials = Data("\u{0}user\u{0}secret".utf8).base64EncodedString()
        let events = session.receive(Data("AUTH PLAIN\r\n".utf8))

        #expect(Self.replies(events) == [SMTPReply(334, "")])
        #expect(Self.replies(events).first?.wireFormat == "334 \r\n")
        #expect(Self.codes(&session, credentials) == [235])
    }

    @Test func authLogin() {
        var session = Self.greetedSession()
        let username = Data("user".utf8).base64EncodedString()
        let password = Data("secret".utf8).base64EncodedString()
        let events = session.receive(Data("AUTH LOGIN\r\n\(username)\r\n\(password)\r\n".utf8))

        #expect(
            Self.replies(events) == [
                SMTPReply(334, "VXNlcm5hbWU6"),
                SMTPReply(334, "UGFzc3dvcmQ6"),
                SMTPReply(235, "Authentication successful"),
            ]
        )
    }

    @Test func authLoginWithInitialUsername() {
        var session = Self.greetedSession()
        let username = Data("user".utf8).base64EncodedString()
        let password = Data("secret".utf8).base64EncodedString()
        #expect(Self.codes(&session, "AUTH LOGIN \(username)", password) == [334, 235])
    }

    @Test func authCanBeCancelled() {
        var session = Self.greetedSession()
        #expect(Self.codes(&session, "AUTH LOGIN", "*", "NOOP") == [334, 501, 250])
    }

    @Test func authRejectsInvalidBase64() {
        var session = Self.greetedSession()
        #expect(Self.codes(&session, "AUTH PLAIN not*base64", "AUTH LOGIN", "%%%", "NOOP") == [501, 334, 501, 250])
    }

    @Test func authErrors() {
        var session = Self.makeSession()
        let credentials = Data("\u{0}user\u{0}secret".utf8).base64EncodedString()
        let codes = Self.codes(
            &session,
            "AUTH PLAIN \(credentials)",
            "EHLO client",
            "AUTH CRAM-MD5",
            "AUTH",
            "MAIL FROM:<a@b>",
            "AUTH PLAIN \(credentials)",
            "RSET",
            "AUTH PLAIN \(credentials)",
            "AUTH PLAIN \(credentials)"
        )
        #expect(codes == [503, 250, 504, 501, 250, 503, 250, 235, 503])
    }

    @Test func authIsOptional() {
        var session = Self.greetedSession()
        let events = session.receive(Data("MAIL FROM:<a@b>\r\nRCPT TO:<c@d>\r\nDATA\r\nx\r\n.\r\n".utf8))
        #expect(Self.messages(events).count == 1)
    }
}
