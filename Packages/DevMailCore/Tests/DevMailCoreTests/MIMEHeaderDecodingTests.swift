import Foundation
import Testing

@testable import DevMailCore

struct EncodedWordDecoderTests {
    @Test(arguments: [
        ("=?UTF-8?B?SGVsbG8gV29ybGQ=?=", "Hello World"),
        ("=?utf-8?q?Hello_World?=", "Hello World"),
        ("=?ISO-8859-1?Q?Caf=E9?=", "Café"),
        ("=?windows-1252?Q?=93quoted=94?=", "“quoted”"),
        ("=?utf-8?Q?a?= =?utf-8?Q?b?=", "ab"),
        ("=?utf-8?Q?a?=\t =?utf-8?Q?b?=", "ab"),
        ("=?utf-8?Q?a?= b =?utf-8?Q?c?=", "a b c"),
        ("Re: =?utf-8?Q?caf=C3=A9?= menu", "Re: café menu"),
        ("=?utf-8*en?Q?language_tag?=", "language tag"),
        ("=?UTF-8?B?8J+R?= =?UTF-8?B?iw==?=", "👋"),
        ("=?utf-8?Q?mixed?= =?ISO-8859-1?Q?_=E9?=", "mixed é"),
        ("plain text = not encoded", "plain text = not encoded"),
        ("=?broken", "=?broken"),
    ])
    func decodes(input: String, expected: String) {
        #expect(EncodedWordDecoder.decode(input) == expected)
    }
}

struct AddressParserTests {
    @Test(arguments: [
        ("jane@example.com", [EmailAddress(address: "jane@example.com")]),
        ("Jane Doe <jane@example.com>", [EmailAddress(name: "Jane Doe", address: "jane@example.com")]),
        (#""Doe, Jane" <jane@example.com>"#, [EmailAddress(name: "Doe, Jane", address: "jane@example.com")]),
        (#""a\"b" <ab@example.com>"#, [EmailAddress(name: #"a"b"#, address: "ab@example.com")]),
        ("jane@example.com (Jane Doe)", [EmailAddress(name: "Jane Doe", address: "jane@example.com")]),
        ("<jane@example.com>", [EmailAddress(address: "jane@example.com")]),
        ("jane@example.com <jane@example.com>", [EmailAddress(address: "jane@example.com")]),
        (
            "a@example.com, B <b@example.com>",
            [EmailAddress(address: "a@example.com"), EmailAddress(name: "B", address: "b@example.com")]
        ),
        (
            "Friends: a@example.com, b@example.com;",
            [EmailAddress(address: "a@example.com"), EmailAddress(address: "b@example.com")]
        ),
        ("undisclosed-recipients:;", []),
        ("=?utf-8?B?Wm/Dqw==?= <zoe@example.com>", [EmailAddress(name: "Zoë", address: "zoe@example.com")]),
        (#""=?utf-8?Q?Zo=C3=AB?=" <zoe@example.com>"#, [EmailAddress(name: "Zoë", address: "zoe@example.com")]),
        ("", []),
    ])
    func parses(input: String, expected: [EmailAddress]) {
        #expect(AddressParser.parse(input) == expected)
    }

    @Test func displayString() {
        #expect(EmailAddress(name: "Jane", address: "jane@example.com").displayString == "Jane <jane@example.com>")
        #expect(EmailAddress(address: "jane@example.com").displayString == "jane@example.com")
    }
}

struct MailDateParserTests {
    @Test(arguments: [
        ("Wed, 21 Oct 2026 14:03:12 +0000", "2026-10-21T14:03:12Z"),
        ("Wed, 21 Oct 2026 09:03:12 -0500", "2026-10-21T14:03:12Z"),
        ("21 Oct 2026 14:03:12 +0000", "2026-10-21T14:03:12Z"),
        ("Wed, 21 Oct 2026 14:03 +0000", "2026-10-21T14:03:00Z"),
        ("Wed,  1 Oct 2026 14:03:12 +0000", "2026-10-01T14:03:12Z"),
        ("Wed, 21 Oct 26 14:03:12 GMT", "2026-10-21T14:03:12Z"),
        ("Wed, 21 Oct 99 14:03:12 UT", "1999-10-21T14:03:12Z"),
        ("Wed, 21 Oct 2026 10:03:12 EDT", "2026-10-21T14:03:12Z"),
        ("Wed, 21 Oct 2026 07:03:12 PDT", "2026-10-21T14:03:12Z"),
        ("Wed, 21 Oct 2026 14:03:12 +0000 (UTC)", "2026-10-21T14:03:12Z"),
        ("Wednesday, 21 October 2026 14:03:12 +0000", "2026-10-21T14:03:12Z"),
        ("Wed, 21-Oct-2026 14:03:12 +0000", "2026-10-21T14:03:12Z"),
        ("Wed Oct 21 14:03:12 2026", "2026-10-21T14:03:12Z"),
        ("2026-10-21T16:03:12+02:00", "2026-10-21T14:03:12Z"),
        ("2026-10-21 14:03:12 +0000", "2026-10-21T14:03:12Z"),
        ("Wed, 21 Oct 2026 14:03:12.123 +0000", "2026-10-21T14:03:12Z"),
        ("Wed, 21 Oct 2026 14:03:12 Z", "2026-10-21T14:03:12Z"),
    ])
    func parses(input: String, expected: String) throws {
        #expect(MailDateParser.parse(input) == (try Fixture.date(expected)))
    }

    @Test(arguments: ["", "yesterday", "Wed, 41 Oct 2026 14:03:12 +0000", "Wed, 21 Foo 2026 14:03:12", "12345"])
    func rejects(input: String) {
        #expect(MailDateParser.parse(input) == nil)
    }
}

struct HeaderValuesTests {
    @Test func parsesContentTypeParameters() {
        let value = HeaderValues.parameterized(#"Text/HTML; Charset="utf-8"; name="a; b.html""#)

        #expect(value.value == "text/html")
        #expect(value.parameters["charset"] == "utf-8")
        #expect(value.parameters["name"] == "a; b.html")
    }

    @Test(arguments: [
        (#"attachment; filename*=UTF-8''%E2%82%AC%20rates.pdf"#, "€ rates.pdf"),
        (#"attachment; filename*=iso-8859-1'en'Caf%E9.txt"#, "Café.txt"),
        (#"attachment; filename*0="long "; filename*1="name.txt""#, "long name.txt"),
        (#"attachment; filename*1="name.txt"; filename*0="long ""#, "long name.txt"),
        (#"attachment; filename*0*=utf-8''%C3%A9t%C3%A9; filename*1=".txt""#, "été.txt"),
        (#"attachment; filename="plain.txt"; filename*=utf-8''pr%C3%A9f%C3%A9r%C3%A9.txt"#, "préféré.txt"),
        (#"attachment; filename="=?utf-8?B?w6l0w6kudHh0?=""#, "été.txt"),
        (#"attachment; filename="r\"q.txt""#, #"r"q.txt"#),
        (#"attachment; filename="../../etc/passwd""#, "../../etc/passwd"),
    ])
    func decodesFilenames(input: String, expected: String) {
        #expect(HeaderValues.parameterized(input).parameters["filename"] == expected)
    }

    @Test func normalizesIdentifiers() {
        #expect(HeaderValues.normalizedIdentifier(" <abc@example.com> ") == "abc@example.com")
        #expect(HeaderValues.normalizedIdentifier("abc@example.com") == "abc@example.com")
    }
}

struct CharsetCase: Sendable, CustomTestStringConvertible {
    let charset: String
    let bytes: [UInt8]
    let expected: String

    var testDescription: String { "\(charset) → \(expected)" }
}

struct CharsetDecoderTests {
    @Test(arguments: [
        CharsetCase(charset: "utf-8", bytes: [0x63, 0x61, 0x66, 0xC3, 0xA9], expected: "café"),
        CharsetCase(charset: "UTF8", bytes: [0x63, 0x61, 0x66, 0xC3, 0xA9], expected: "café"),
        CharsetCase(charset: "iso-8859-1", bytes: [0x63, 0x61, 0x66, 0xE9], expected: "café"),
        CharsetCase(charset: "ISO-8859-2", bytes: [0xB3, 0xF3, 0x64, 0xBC], expected: "łódź"),
        CharsetCase(charset: "iso-8859-15", bytes: [0xA4], expected: "€"),
        CharsetCase(charset: "windows-1252", bytes: [0x80, 0x93, 0x94], expected: "€“”"),
        CharsetCase(charset: "windows-1251", bytes: [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2], expected: "Привет"),
        CharsetCase(charset: "cp1252", bytes: [0x80], expected: "€"),
        CharsetCase(charset: "us-ascii", bytes: [0x63, 0x61, 0x66, 0xC3, 0xA9], expected: "café"),
        CharsetCase(charset: "x-made-up", bytes: [0x63, 0x61, 0x66, 0xC3, 0xA9], expected: "café"),
        CharsetCase(charset: "x-made-up", bytes: [0x63, 0x61, 0x66, 0xE9], expected: "café"),
        CharsetCase(charset: "utf-8", bytes: [0x63, 0x61, 0x66, 0xE9], expected: "café"),
    ])
    func decodes(testCase: CharsetCase) {
        #expect(CharsetDecoder.decode(testCase.bytes, charset: testCase.charset) == testCase.expected)
    }
}

struct TransferDecoderTests {
    @Test func decodesBase64WithLineBreaksAndJunk() {
        let input = Array("SGVs\r\nbG8g\nV29y*bGQ=".utf8)
        #expect(TransferDecoder.decodeBase64(input) == Array("Hello World".utf8))
    }

    @Test func decodesQuotedPrintable() {
        let input = Array("caf=C3=A9 soft=\r\nbreak trailing= \nok =3d =zz".utf8)
        #expect(
            String(bytes: TransferDecoder.decodeQuotedPrintable(input), encoding: .utf8)
                == "café softbreak trailingok = =zz"
        )
    }

    @Test(arguments: ["7bit", "8bit", "binary", "x-unknown", "BINARY "])
    func passesThroughIdentityEncodings(encoding: String) {
        let bytes: [UInt8] = [0x00, 0xFF, 0x0D, 0x0A, 0x41]
        #expect(TransferDecoder.decode(bytes[...], encoding: encoding) == Data(bytes))
    }
}
