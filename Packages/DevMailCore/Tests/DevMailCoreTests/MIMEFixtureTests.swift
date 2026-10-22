import Foundation
import Testing

@testable import DevMailCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "eml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func message(_ name: String) throws -> ParsedMessage {
        MIMEParser.parse(try data(name))
    }

    static func date(_ iso8601: String) throws -> Date {
        try Date(iso8601, strategy: .iso8601)
    }
}

struct MIMEFixtureTests {
    @Test func laravelQuotedPrintableAlternative() throws {
        let message = try Fixture.message("laravel-welcome")

        #expect(message.subject == "Welcome to Acme 🎉 — let’s get started")
        #expect(message.from == [EmailAddress(name: "Acme App", address: "hello@acme.test")])
        #expect(message.to == [EmailAddress(name: "Taylor Otwell", address: "taylor@example.com")])
        #expect(message.messageID == "5f1c0a3e9b2d8c7a6e4f1b0d9c8a7e6f@acme.test")
        #expect(message.date == (try Fixture.date("2026-10-21T14:03:12Z")))

        let text = try #require(message.textBody)
        #expect(text.contains("Thanks for signing up for Acme — we’re glad you’re here."))
        #expect(text.contains("https://acme.test/verify?token=abc123&expires=1792400000"))
        #expect(!text.contains("\r"))

        let html = try #require(message.htmlBody)
        #expect(html.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0">"#))
        #expect(
            html.contains(#"<table class="wrapper" width="100%" cellpadding="0" cellspacing="0" role="presentation">"#)
        )
        #expect(message.attachments.isEmpty)
        #expect(message.headerValue(named: "x-laravel-mailable") == #"App\Mail\WelcomeMail"#)
    }

    @Test func railsNestedMixedWithAttachment() throws {
        let message = try Fixture.message("rails-invoice")

        #expect(message.subject == "Your invoice #1042")
        #expect(message.to == [EmailAddress(name: "Hansson, David", address: "david@example.com")])
        #expect(
            message.cc == [
                EmailAddress(address: "accounts@example.com"),
                EmailAddress(name: "Jason (Ops)", address: "jason@example.com"),
            ]
        )
        #expect(message.replyTo == [EmailAddress(address: "support@shop.test")])
        #expect(message.date == (try Fixture.date("2026-10-21T14:15:00Z")))
        #expect(message.textBody?.hasPrefix("Hi David,\n\nYour invoice #1042 for $120.00 is attached.") == true)
        #expect(message.htmlBody?.contains("<strong>#1042</strong>") == true)

        let invoice = try #require(message.attachments.first)
        #expect(message.attachments.count == 1)
        #expect(invoice.filename == "invoice-1042.pdf")
        #expect(invoice.mimeType == "application/pdf")
        #expect(invoice.size == 44)
        #expect(String(bytes: invoice.data, encoding: .utf8)?.hasPrefix("%PDF-1.4") == true)

        // ActionMailer gives every attachment a Content-ID; an explicit attachment disposition keeps it listed.
        #expect(invoice.contentID == "6536f2a1cb3e4_3a2f1c0e4d8c9@rails-worker-1.mail")
        #expect(message.inlinePart(contentID: "<6536f2a1cb3e4_3a2f1c0e4d8c9@rails-worker-1.mail>") == invoice)
    }

    @Test func djangoEncodedWordsAnd8bitWithLFLineEndings() throws {
        let message = try Fixture.message("django-report")

        #expect(message.subject == "Your weekly report is ready ✅")
        #expect(message.from == [EmailAddress(name: "Café Reports", address: "reports@cafe.test")])
        #expect(message.to == [EmailAddress(name: "Zoë Ångström", address: "zoe@example.com")])
        #expect(message.date == (try Fixture.date("2026-10-21T14:03:12Z")))
        #expect(message.textBody?.contains("Hello Zoë,") == true)
        #expect(message.textBody?.contains("— The Café team") == true)
        #expect(message.htmlBody?.hasPrefix("<p>Hello Zoë,</p>") == true)
        #expect(
            message.snippet
                == "Hello Zoë, Your weekly report is ready: 12 new signups, 3 cancellations. — The Café team"
        )
    }

    @Test func nodemailerRelatedInlineImageAndRFC2231Attachment() throws {
        let message = try Fixture.message("nodemailer-receipt")

        // Two B-encoded words splitting a four-byte emoji must be joined before charset decoding.
        #expect(message.subject == "Grüße 👋 aus Zürich")
        #expect(message.from == [EmailAddress(name: "Acme, Inc.", address: "receipts@acme.test")])
        #expect(message.textBody == "Thanks for your order!\nOrder #A-1042 - total $42.00")

        let html = try #require(message.htmlBody)
        #expect(html.contains(#"<img src="cid:logo@acme.test" alt="Acme">"#))

        let logo = try #require(message.inlinePart(contentID: "logo@acme.test"))
        #expect(logo.mimeType == "image/png")
        #expect(logo.filename == "logo.png")
        #expect(logo.size == 70)
        #expect(logo.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(message.inlineParts.count == 1)

        let csv = try #require(message.attachments.first)
        #expect(message.attachments.count == 1)
        #expect(csv.filename == "Reçu détaillé - octobre.csv")
        #expect(csv.mimeType == "text/csv")
        #expect(String(bytes: csv.data, encoding: .utf8)?.contains("Café crème") == true)

        #expect(message.snippet == "Thanks for your order! Order #A-1042 - total $42.00")

        var htmlOnly = message
        htmlOnly.textBody = nil
        #expect(htmlOnly.snippet == "Your receipt from Acme Thanks for your order! Order #A-1042 — total $42.00")
    }

    @Test func transactionalProviderLegacyCharsets() throws {
        let message = try Fixture.message("transactional-payment")

        #expect(message.subject == "Zahlung erhalten: € 42,00")
        #expect(message.to == [EmailAddress(name: "Jürgen Müller", address: "kunde@example.com")])
        #expect(message.date == (try Fixture.date("2026-10-21T14:03:12Z")))
        #expect(message.textBody == "Danke – Ihre Zahlung über €42,00 ist eingegangen.")
        #expect(message.htmlBody?.contains("Danke, Jürgen! Ihre Zahlung über &euro;42,00 ist eingegangen.") == true)

        let banner = try #require(message.inlinePart(contentID: "banner"))
        #expect(banner.mimeType == "image/gif")
        #expect(banner.filename == nil)
        #expect(banner.size == 42)

        let receipt = try #require(message.attachments.first)
        #expect(message.attachments.count == 1)
        #expect(receipt.filename == "Quittung für Oktober.pdf")
        #expect(receipt.contentID == nil)

        let received = message.headers.filter { $0.name == "Received" }
        #expect(received.first?.value.contains("by mx.example.com with ESMTPS id 4XyZ1q2w3e") == true)
        #expect(message.headers.first?.name == "Return-Path")
    }

    @Test func headerEdgeCases() throws {
        let message = try Fixture.message("headers-edge-cases")

        #expect(message.subject == "This subject is folded  across two lines")
        #expect(message.from == [EmailAddress(name: #"Doe, Jane "JD""#, address: "jane@example.com")])
        #expect(
            message.to == [
                EmailAddress(address: "alice@example.com"),
                EmailAddress(name: "Bob B.", address: "bob@example.com"),
                EmailAddress(name: "Carol C.", address: "carol@example.com"),
            ]
        )
        #expect(message.cc.isEmpty)
        #expect(message.bcc == [EmailAddress(address: "dave@example.com")])
        #expect(
            message.replyTo == [
                EmailAddress(name: "Help Desk", address: "help@example.com"),
                EmailAddress(name: "Équipe Support", address: "support@example.com"),
            ]
        )
        #expect(message.date == (try Fixture.date("2026-10-21T15:00:00Z")))
        #expect(message.messageID == "folded-id@example.com")
        #expect(message.headerValue(named: "X-Long-Header") == "one\ttwo\tthree")
        #expect(message.headers.first?.name == "From")
        #expect(message.textBody == "Body after a header block with every quirk we could think of.\n")
    }
}
