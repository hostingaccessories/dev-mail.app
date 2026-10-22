import CoreServices
import DevMailCore
import Foundation
import UniformTypeIdentifiers

/// Turns a sender-supplied attachment filename into a single, safe file name.
///
/// The result is never empty, contains no path separators, control characters or bidi overrides, never starts with
/// a dot, and is at most `maxBytes` bytes of UTF-8.
nonisolated enum AttachmentFilename {
    static let maxBytes = 200
    static let fallbackBaseName = "attachment"

    /// Extensions longer than this are treated as part of the name when truncating.
    private static let maxExtensionBytes = 20

    /// Bidi controls can disguise an extension, e.g. "invoice\u{202E}fdp.exe" displays as "invoiceexe.pdf".
    private static let bidiControls: Set<Unicode.Scalar> = [
        "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]

    static func sanitized(_ filename: String?, mimeType: String) -> String {
        var name = (filename ?? "").precomposedStringWithCanonicalMapping

        // Control characters (including NUL, tabs and newlines) and bidi controls are removed.
        name.unicodeScalars.removeAll { $0.properties.generalCategory == .control || bidiControls.contains($0) }

        // Only the last path component survives: "../../etc/passwd" becomes "passwd", "C:\x\y.exe" becomes "y.exe".
        name = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""

        // ":" is the classic Mac OS path separator and shows as "/" in Finder.
        name = name.replacingOccurrences(of: ":", with: "-")

        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        // A leading dot would hide the file; "." and ".." become empty.
        name = String(name.drop { $0 == "." || $0 == " " })

        name = truncated(name)

        if name.isEmpty {
            let fallbackExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension
            return fallbackExtension.map { "\(fallbackBaseName).\($0)" } ?? fallbackBaseName
        }
        return name
    }

    /// Shortens the name to `maxBytes` UTF-8 bytes on a character boundary, keeping a short extension intact.
    private static func truncated(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }

        let pathExtension = (name as NSString).pathExtension
        let keepsExtension = !pathExtension.isEmpty && pathExtension.utf8.count <= maxExtensionBytes
        let suffix = keepsExtension ? "." + pathExtension : ""
        var base = keepsExtension ? String(name.dropLast(suffix.count)) : name

        while !base.isEmpty && base.utf8.count + suffix.utf8.count > maxBytes {
            base.removeLast()
        }
        base = String(base.reversed().drop { $0 == " " }.reversed())
        return base + suffix
    }
}

extension MessagePart {
    /// The file name the attachment is shown, written and saved under.
    nonisolated var safeFilename: String {
        AttachmentFilename.sanitized(filename, mimeType: mimeType)
    }

    /// The type to show an icon and description for: from the file extension when the system knows it, otherwise
    /// from the declared MIME type.
    nonisolated var contentType: UTType {
        let pathExtension = (safeFilename as NSString).pathExtension
        if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension), !type.isDynamic {
            return type
        }
        return UTType(mimeType: mimeType) ?? .data
    }
}

/// Writes attachments to a private temporary folder so Quick Look and drag and drop have a file URL to work with.
///
/// Layout: `<root>/<message id>/<attachment index>/<sanitised name>`. Folders are 0700 and files 0600, and every file
/// is quarantined so the system treats it as downloaded. The sender's filename only ever chooses the last path
/// component, after sanitising. The whole folder is removed at launch and at quit.
nonisolated struct AttachmentFileStore: Sendable {
    static let shared = AttachmentFileStore(
        root: FileManager.default.temporaryDirectory.appending(path: "DevMail-Attachments", directoryHint: .isDirectory)
    )

    let root: URL

    enum Failure: Error, LocalizedError {
        case outsideRoot

        var errorDescription: String? {
            "The attachment couldn't be written to the temporary folder."
        }
    }

    /// Returns the attachment's file, writing it first unless an identical-size regular file is already there.
    func fileURL(for part: MessagePart, index: Int, messageID: UUID) throws -> URL {
        let fileManager = FileManager.default
        let directory =
            root
            .appending(path: messageID.uuidString, directoryHint: .isDirectory)
            .appending(path: String(index), directoryHint: .isDirectory)
        let file = directory.appending(path: part.safeFilename, directoryHint: .notDirectory)
        guard file.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path,
            directory.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
        else { throw Failure.outsideRoot }

        // attributesOfItem doesn't follow symlinks, so only a real file we wrote earlier is reused.
        if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.intValue == part.size
        {
            return file
        }

        try createPrivateDirectory(directory)
        try part.data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Self.quarantine(file)
        return file
    }

    /// Deletes every written attachment.
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Marks a file as downloaded from the internet, so opening it goes through Gatekeeper.
    static func quarantine(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Dev Mail",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        try url.setResourceValues(values)
    }

    /// Creates the folder and every missing parent below `root` with 0700, and tightens any that already exist.
    private func createPrivateDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var current = directory
        while current.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
            current = current.deletingLastPathComponent()
        }
    }
}
