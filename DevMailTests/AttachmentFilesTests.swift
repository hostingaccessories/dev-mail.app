import DevMailCore
import Foundation
import Testing

@testable import DevMail

struct AttachmentFilenameTests {
    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        ("../../etc/passwd", "passwd"),
        ("..", "attachment.pdf"),
        ("../..", "attachment.pdf"),
        ("/absolute/path/file.txt", "file.txt"),
        (#"C:\Users\evil\payload.exe"#, "payload.exe"),
        (#"..\..\boot.ini"#, "boot.ini"),
        ("dir/", "dir"),
        (".hidden", "hidden"),
        ("...profile", "profile"),
        ("a:b.txt", "a-b.txt"),
        ("nul\u{0}byte.txt", "nulbyte.txt"),
        ("line\nbreak\r\tname.txt", "linebreakname.txt"),
        ("bell\u{07}\u{7F}.txt", "bell.txt"),
        ("invoice\u{202E}fdp.exe", "invoicefdp.exe"),
        ("  lots   of\u{00A0}  space  .txt  ", "lots of space .txt"),
        ("Résumé 日本語 📎.docx", "Résumé 日本語 📎.docx"),
    ])
    func sanitizes(input: String, expected: String) {
        #expect(AttachmentFilename.sanitized(input, mimeType: "application/pdf") == expected)
    }

    @Test func normalizesToPrecomposedForm() {
        let decomposed = "Re\u{0301}sume\u{0301}.txt"

        #expect(AttachmentFilename.sanitized(decomposed, mimeType: "text/plain") == "R\u{00E9}sum\u{00E9}.txt")
    }

    @Test func fallsBackToMIMETypeExtension() {
        #expect(AttachmentFilename.sanitized(nil, mimeType: "image/png") == "attachment.png")
        #expect(AttachmentFilename.sanitized("", mimeType: "text/plain") == "attachment.txt")
        #expect(AttachmentFilename.sanitized("/// \u{0}", mimeType: "application/pdf") == "attachment.pdf")
        #expect(AttachmentFilename.sanitized(nil, mimeType: "application/x-unknown-thing") == "attachment")
    }

    @Test func capsLengthAndKeepsExtension() {
        let name = String(repeating: "a", count: 500) + ".pdf"

        let sanitized = AttachmentFilename.sanitized(name, mimeType: "application/pdf")

        #expect(sanitized.utf8.count == AttachmentFilename.maxBytes)
        #expect(sanitized.hasSuffix("a.pdf"))
    }

    @Test func capsMultibyteNamesOnCharacterBoundaries() {
        let name = String(repeating: "日", count: 100) + ".txt"

        let sanitized = AttachmentFilename.sanitized(name, mimeType: "text/plain")

        #expect(sanitized.utf8.count <= AttachmentFilename.maxBytes)
        #expect(sanitized.hasSuffix("日.txt"))
        #expect(sanitized.dropLast(4).allSatisfy { $0 == "日" })
    }

    @Test func capsNamesWithAHugeExtension() {
        let name = "x." + String(repeating: "e", count: 300)

        let sanitized = AttachmentFilename.sanitized(name, mimeType: "text/plain")

        #expect(sanitized.utf8.count == AttachmentFilename.maxBytes)
        #expect(sanitized.hasPrefix("x.eee"))
    }

    @Test(arguments: ["../../x", "a/b\\c", "\u{0}", ".", "...", String(repeating: "/", count: 300)])
    func neverProducesPathSeparatorsOrLeadingDots(input: String) {
        let sanitized = AttachmentFilename.sanitized(input, mimeType: "text/plain")

        #expect(!sanitized.isEmpty)
        #expect(!sanitized.contains("/"))
        #expect(!sanitized.contains("\\"))
        #expect(!sanitized.hasPrefix("."))
        #expect(sanitized != "..")
    }
}

@Suite(.serialized)
struct AttachmentFileStoreTests {
    private let store: AttachmentFileStore
    private let messageID = UUID()

    init() {
        store = AttachmentFileStore(
            root: FileManager.default.temporaryDirectory
                .appending(path: "DevMailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
    }

    @Test func writesPrivateQuarantinedFileInsideRoot() throws {
        defer { store.removeAll() }
        let part = MessagePart(filename: "../../../escape.txt", mimeType: "text/plain", data: Data("hello".utf8))

        let url = try store.fileURL(for: part, index: 0, messageID: messageID)

        #expect(url.lastPathComponent == "escape.txt")
        #expect(url.standardizedFileURL.path.hasPrefix(store.root.standardizedFileURL.path + "/"))
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        #expect(try permissions(of: url) == 0o600)
        #expect(try permissions(of: url.deletingLastPathComponent()) == 0o700)
        #expect(try permissions(of: url.deletingLastPathComponent().deletingLastPathComponent()) == 0o700)
        #expect(try permissions(of: store.root) == 0o700)
        #expect(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    }

    @Test func keepsSameNamedAttachmentsApart() throws {
        defer { store.removeAll() }
        let first = MessagePart(filename: "image.png", mimeType: "image/png", data: Data([1]))
        let second = MessagePart(filename: "image.png", mimeType: "image/png", data: Data([2, 2]))

        let firstURL = try store.fileURL(for: first, index: 0, messageID: messageID)
        let secondURL = try store.fileURL(for: second, index: 1, messageID: messageID)

        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == Data([1]))
        #expect(try Data(contentsOf: secondURL) == Data([2, 2]))
    }

    @Test func reusesWrittenFile() throws {
        defer { store.removeAll() }
        let part = MessagePart(filename: "a.txt", mimeType: "text/plain", data: Data("abc".utf8))
        let url = try store.fileURL(for: part, index: 0, messageID: messageID)
        let firstWrite = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        let again = try store.fileURL(for: part, index: 0, messageID: messageID)

        #expect(again == url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int == firstWrite)
    }

    @Test func replacesSymlinkInsteadOfFollowingIt() throws {
        defer { store.removeAll() }
        let part = MessagePart(filename: "a.txt", mimeType: "text/plain", data: Data("abc".utf8))
        let url = try store.fileURL(for: part, index: 0, messageID: messageID)
        let target = store.root.appending(path: "target.txt")
        try Data("xyz".utf8).write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        let rewritten = try store.fileURL(for: part, index: 0, messageID: messageID)

        let type = try FileManager.default.attributesOfItem(atPath: rewritten.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(try Data(contentsOf: target) == Data("xyz".utf8))
    }

    @Test func removeAllDeletesRoot() throws {
        let part = MessagePart(filename: "a.txt", mimeType: "text/plain", data: Data("abc".utf8))
        _ = try store.fileURL(for: part, index: 0, messageID: messageID)

        store.removeAll()

        #expect(!FileManager.default.fileExists(atPath: store.root.path))
    }

    private func permissions(of url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}

struct MessagePartContentTypeTests {
    @Test func prefersKnownExtension() {
        let part = MessagePart(filename: "doc.pdf", mimeType: "application/octet-stream", data: Data())

        #expect(part.contentType == .pdf)
    }

    @Test func fallsBackToMIMEType() {
        let part = MessagePart(filename: "noextension", mimeType: "image/png", data: Data())

        #expect(part.contentType == .png)
    }
}
