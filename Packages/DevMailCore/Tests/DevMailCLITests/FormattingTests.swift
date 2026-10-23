import DevMailCore
import Foundation
import Testing

@testable import DevMailCLI

struct FormattingTests {
    private let formatting = MessageFormatting(
        style: .plain,
        now: Fixtures.now,
        timeZone: .gmt,
        locale: Locale(identifier: "en_US_POSIX")
    )

    @Test func listsMessagesInAlignedColumns() {
        let read = Fixtures.summary(subject: "Welcome", receivedAt: Fixtures.now - 60, isRead: true)
        var unread = Fixtures.summary(subject: nil, receivedAt: Fixtures.now - 86_400 * 40, hasAttachments: true)
        unread.sender = EmailAddress(name: "A Very Long Sender Name Indeed", address: "sender@example.com")

        let lines = formatting.table([read, unread]).components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("ID        RECEIVED            FROM                          TO  "))
        #expect(lines[1].hasPrefix("\(MessageIDMatcher.shortID(read.id))  11:59\u{202F}AM            App <"))
        #expect(lines[1].hasSuffix("  Welcome"))
        #expect(lines[2].contains("  Sep 15 at 12:00\u{202F}PM  "))
        #expect(lines[2].contains("A Very Long Sender Name Ind…"))
        #expect(lines[2].hasSuffix("  (no subject) 📎"))
        #expect(formatting.table([]) == "No messages.")
    }

    @Test func datesListsByAge() {
        // ICU puts a narrow no-break space before AM and PM.
        #expect(formatting.listDate(Fixtures.now - 3_600) == "11:00\u{202F}AM")
        #expect(formatting.listDate(Fixtures.now - 86_400 * 2) == "Oct 23 at 12:00\u{202F}PM")
        #expect(formatting.listDate(Fixtures.now - 86_400 * 365) == "Oct 25, 2025")
    }

    @Test func boldsUnreadRowsWhenStyled() {
        var styled = formatting
        styled.style = TerminalStyle(isEnabled: true)
        let unread = Fixtures.summary(subject: "Hi", receivedAt: Fixtures.now, isRead: false)
        let lines = styled.table([unread]).components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("\u{1B}[2m"))
        #expect(lines[1].hasPrefix("\u{1B}[1m"))
    }

    @Test func showsMessageWithBccAndAttachments() {
        let raw = """
            From: App <app@example.com>\r
            To: Jane <jane@example.com>\r
            Subject: Your receipt\r
            Date: Sun, 25 Oct 2026 12:00:00 +0000\r
            Content-Type: multipart/mixed; boundary=b\r
            \r
            --b\r
            Content-Type: text/plain\r
            \r
            Thanks!\r
            --b\r
            Content-Type: text/csv\r
            Content-Disposition: attachment; filename=receipt.csv\r
            \r
            a,b\r
            --b--\r

            """
        var summary = Fixtures.summary(subject: "Your receipt", receivedAt: Fixtures.now)
        summary.envelopeRecipients = ["jane@example.com", "audit@example.com"]

        let text = formatting.message(summary, parsed: MIMEParser.parse(Data(raw.utf8)))
        #expect(
            text == """
                From:    App <app@example.com>
                To:      Jane <jane@example.com>
                Bcc:     audit@example.com
                Subject: Your receipt
                Date:    Sunday, October 25, 2026 at 12:00:00\u{202F}PM
                ID:      \(summary.id.uuidString.lowercased())

                Thanks!

                Attachments:
                  receipt.csv (text/csv, 3 bytes)
                """
        )
    }

    @Test func showsStatusAndSettings() {
        let app = AppFormatting(style: .plain)
        let status = ControlServerStatus(
            state: .failed,
            host: "::1",
            port: 1025,
            failureReason: "Port 1025 is already in use by another application.",
            messageCount: 3,
            unreadCount: 1,
            messagesDirectory: "/tmp/Messages"
        )
        #expect(
            app.status(status) == """
                Server:   failed on [::1]:1025: Port 1025 is already in use by another application.
                Messages: 3 (1 unread)
                Folder:   /tmp/Messages
                """
        )

        let settings = ControlSettings(
            host: "127.0.0.1",
            port: 2525,
            limitsMessageCount: true,
            maxMessageCount: 500,
            limitsMessageAge: false,
            maxAgeInDays: 30,
            showsMenuBarItem: false,
            hidesDockIcon: true,
            opensAtLogin: true
        )
        #expect(
            app.settings(settings) == """
                Host:          127.0.0.1
                Port:          2525
                Keep:          the most recent 500 messages
                Delete after:  never
                Menu bar item: off
                Dock icon:     shown (hidden only while the menu bar item is on)
                Open at login: on
                """
        )
    }

    @Test(arguments: [
        ([String: String](), true),
        (["NO_COLOR": "1"], false),
        (["NO_COLOR": ""], true),
        (["TERM": "dumb"], false),
    ])
    func respectsNoColor(environment: [String: String], styledWhenTerminal: Bool) {
        // Tests don't run on a terminal, so only the environment can be checked to switch styling off.
        if !styledWhenTerminal {
            #expect(!TerminalStyle.forStandardOutput(environment: environment).isEnabled)
        }
        #expect(TerminalStyle.plain.bold("x") == "x")
    }
}

enum Fixtures {
    /// Sunday, October 25, 2026, 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_792_929_600)

    static func summary(
        subject: String?,
        receivedAt: Date,
        isRead: Bool = false,
        hasAttachments: Bool = false
    ) -> MessageSummary {
        MessageSummary(
            id: UUID(),
            sender: EmailAddress(name: "App", address: "app@example.com"),
            recipients: ["Jane <jane@example.com>"],
            envelopeSender: "app@example.com",
            envelopeRecipients: ["jane@example.com"],
            subject: subject,
            date: receivedAt,
            receivedAt: receivedAt,
            size: 100,
            snippet: "",
            hasAttachments: hasAttachments,
            isRead: isRead
        )
    }
}
