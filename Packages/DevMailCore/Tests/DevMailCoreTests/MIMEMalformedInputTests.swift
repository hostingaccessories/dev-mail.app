import Foundation
import Testing

@testable import DevMailCore

struct MIMEMalformedInputTests {
    @Test func guessesMissingBoundary() throws {
        let message = try Fixture.message("broken-missing-boundary")

        #expect(message.textBody == "Plain part found by guessing the boundary.")
        #expect(message.htmlBody == "<p>HTML part found by guessing the boundary.</p>")
    }

    @Test func treatsHeaderlessInputAsBody() throws {
        let message = try Fixture.message("broken-no-headers")

        #expect(message.headers.isEmpty)
        #expect(message.subject == nil)
        #expect(message.textBody?.hasPrefix("This message has no header block at all.\nJust a body:") == true)
    }

    @Test func recoversFromBrokenHeadersEncodingsAndMissingCloseDelimiter() throws {
        let message = try Fixture.message("broken-unterminated")

        #expect(message.from.isEmpty)
        #expect(message.to == [EmailAddress(address: "nobody")])
        #expect(message.date == nil)
        // Unknown charset falls back to Windows-1252; an unterminated encoded word is left as-is.
        #expect(message.subject?.hasPrefix("Mojibake café and ") == true)
        #expect(message.subject?.hasSuffix(" =?utf-8?Q?unterminated") == true)
        #expect(message.textBody == "Café crème in an unknown charset, falling back sensibly.")
        #expect(message.htmlBody == "<p>Binary transfer encoding: naïve résumé</p>")

        #expect(message.attachments.map(\.filename) == ["unterminated.txt", "truncated.bin", "notes.txt"])
        let garbage = message.attachments[0]
        #expect(garbage.mimeType == "text/plain")
        #expect(garbage.data == Data("raw uuencoded-ish content".utf8))

        let truncated = message.attachments[1]
        #expect(truncated.mimeType == "application/octet-stream")
        #expect(!truncated.data.isEmpty)

        let notes = message.attachments[2]
        #expect(
            String(bytes: notes.data, encoding: .utf8)
                == "Invalid QP =ZZ stays literal, a lone = at end\nand the message just stops without a close delimiter"
        )
    }

    @Test func decodesInvalidUTF8BodyLossily() throws {
        let message = try Fixture.message("broken-binary-body")

        #expect(message.subject == "Binary junk")
        #expect(message.textBody?.contains("invalid UTF-8") == true)
    }

    @Test func boundsMultipartNestingDepth() {
        var message = "Content-Type: multipart/mixed; boundary=b0\n\n"
        let depth = 200
        for level in 1...depth {
            message += "--b\(level - 1)\nContent-Type: multipart/mixed; boundary=b\(level)\n\n"
        }
        message += "--b\(depth)\nContent-Type: text/plain\n\ntoo deep\n"

        let parsed = MIMEParser.parse(Data(message.utf8))

        #expect(parsed.textBody == nil)
        #expect(parsed.attachments.isEmpty)
    }

    @Test func keepsShallowNestingWithinLimit() {
        var message = "Content-Type: multipart/mixed; boundary=b0\n\n"
        let depth = 10
        for level in 1...depth {
            message += "--b\(level - 1)\nContent-Type: multipart/mixed; boundary=b\(level)\n\n"
        }
        message += "--b\(depth)\nContent-Type: text/plain\n\nnested text\n--b\(depth)--\n"

        #expect(MIMEParser.parse(Data(message.utf8)).textBody == "nested text")
    }

    @Test func capsHugeHeaders() {
        let longValue = String(repeating: "a", count: 200_000)
        var message = "Subject: \(longValue)\n"
        message += String(repeating: " continued\n", count: 10_000)
        message += String(repeating: "X-Spam: 1\n", count: 5_000)
        message += "\nbody\n"

        let parsed = MIMEParser.parse(Data(message.utf8))

        #expect(parsed.headers.count == HeaderParser.maxHeaderCount)
        #expect((parsed.subject?.utf8.count ?? 0) <= HeaderParser.maxValueLength)
        #expect(parsed.textBody == "body\n")
    }

    @Test func capsPartCount() {
        var message = "Content-Type: multipart/mixed; boundary=x\n\n"
        message += String(repeating: "--x\nContent-Type: application/octet-stream\n\nA\n", count: 5_000)
        message += "--x--\n"

        let parsed = MIMEParser.parse(Data(message.utf8))

        #expect(parsed.attachments.count == MIMEParser.maxPartCount - 1)
    }

    @Test func survivesDegenerateInputs() {
        let inputs: [String] = [
            "",
            "\n",
            "\r\n\r\n",
            ":",
            ": no name\n\nbody",
            "Subject:",
            "Content-Type: multipart/mixed; boundary=\"\"\n\n--\n--\n",
            "Content-Type: multipart/mixed; boundary=x\n\n--x",
            "Content-Type: multipart/mixed; boundary=x\n\n--x--",
            "Content-Type: ;;;;==;\"\n\nbody",
            "Content-Type: text/plain; charset*0*=''; name*999999999999999999999=x\n\nbody",
            "Subject: =?\n\n",
            "Subject: =?utf-8?\n\n",
            "Subject: =?utf-8?B?\n\n",
            "Subject: =?utf-8?Z?abc?=\n\n",
            "Content-Transfer-Encoding: quoted-printable\n\n=",
            "Content-Transfer-Encoding: quoted-printable\n\n=4",
            "Content-Transfer-Encoding: base64\n\n====",
            "From: \"unterminated <a@b>\nTo: (unterminated comment <c@d>\nDate: 99 Foo 99999 99:99:99\n\n",
        ]
        for input in inputs {
            _ = MIMEParser.parse(Data(input.utf8))
        }

        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let bytes = (0..<Int.random(in: 0..<2_000, using: &generator)).map { _ in
                UInt8.random(in: 0...255, using: &generator)
            }
            _ = MIMEParser.parse(Data(bytes))
        }
    }

    @Test func treatsLFAndCRLFIdentically() throws {
        let crlf = try Fixture.data("nodemailer-receipt")
        let lfOnly = Data(crlf.split(separator: ASCII.carriageReturn).joined())

        let fromCRLF = MIMEParser.parse(crlf)
        let fromLF = MIMEParser.parse(lfOnly)

        #expect(fromCRLF.headers == fromLF.headers)
        #expect(fromCRLF.textBody == fromLF.textBody)
        #expect(fromCRLF.htmlBody == fromLF.htmlBody)
        #expect(fromCRLF.attachments == fromLF.attachments)
        #expect(fromCRLF.inlineParts == fromLF.inlineParts)
    }
}
