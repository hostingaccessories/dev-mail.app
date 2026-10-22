import Darwin
import Foundation

/// A `.eml` file in the messages folder, identified from its name alone.
struct MessageFile: Equatable {
    var id: UUID
    var receivedAt: Date
    var url: URL
}

/// File-system access for the messages folder: secure creation, atomic writes, naming and extended attributes.
struct MessageDirectory: Sendable {
    static let indexFileName = "index.json"
    private static let metadataAttribute = "app.devmail.metadata"
    private static let temporaryPrefix = ".tmp-"

    let url: URL

    var indexURL: URL { url.appending(path: Self.indexFileName, directoryHint: .notDirectory) }

    /// Creates the folder if needed and restricts it to the current user.
    func prepare() throws(MessageStoreError) {
        let path = url.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            throw .directoryUnavailable(path: path, reason: error.localizedDescription)
        }
    }

    // MARK: - Naming

    /// `<receivedAt in ms, zero-padded>-<lowercase uuid>.eml`, so a plain directory listing sorts by arrival time.
    /// `receivedAt` is expected to be whole milliseconds already; rounding absorbs floating-point error.
    func fileURL(id: UUID, receivedAt: Date) -> URL {
        url.appending(path: Self.fileName(id: id, receivedAt: receivedAt), directoryHint: .notDirectory)
    }

    private static func fileName(id: UUID, receivedAt: Date) -> String {
        let millis = Int64((receivedAt.timeIntervalSince1970 * 1_000).rounded())
        return String(format: "%013lld-%@.eml", millis, id.uuidString.lowercased())
    }

    /// Parses a name produced by `fileURL(id:receivedAt:)`. Anything else, including a differently formatted name
    /// for a valid ID, is ignored so every indexed message maps back to exactly one file.
    static func messageFile(named name: String, in directory: URL) -> MessageFile? {
        guard name.hasSuffix(".eml") else { return nil }
        let stem = name.dropLast(4)
        guard let dash = stem.firstIndex(of: "-"),
            let millis = Int64(stem[..<dash]), millis >= 0,
            let id = UUID(uuidString: String(stem[stem.index(after: dash)...]))
        else { return nil }
        let receivedAt = Date(timeIntervalSince1970: Double(millis) / 1_000)
        guard fileName(id: id, receivedAt: receivedAt) == name else { return nil }
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        return MessageFile(id: id, receivedAt: receivedAt, url: url)
    }

    /// Every correctly named `.eml` file, keyed by message ID.
    func messageFiles() throws(MessageStoreError) -> [UUID: MessageFile] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
        } catch {
            throw .readFailed(path: url.path(percentEncoded: false), reason: error.localizedDescription)
        }
        var files: [UUID: MessageFile] = [:]
        for name in names {
            if let file = Self.messageFile(named: name, in: url) {
                files[file.id] = file
            }
        }
        return files
    }

    /// Deletes temporary files left behind by a write that was interrupted, e.g. by a crash.
    func removeStaleTemporaryFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(Self.temporaryPrefix) {
            try? FileManager.default.removeItem(at: url.appending(path: name, directoryHint: .notDirectory))
        }
    }

    // MARK: - Reading and writing

    func read(_ fileURL: URL) throws(MessageStoreError) -> Data {
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw .readFailed(path: fileURL.path(percentEncoded: false), reason: error.localizedDescription)
        }
    }

    func remove(_ fileURL: URL) throws(MessageStoreError) {
        let path = fileURL.path(percentEncoded: false)
        guard unlink(path) == 0 || errno == ENOENT else {
            throw .writeFailed(path: path, reason: Self.describe(errno))
        }
    }

    /// Writes to a `0600` temporary file in the same folder, then renames it over `destination`, so readers never
    /// see a partial file and the contents are never readable by other users. Metadata is attached before the
    /// rename so the file never appears without it.
    func writeAtomically(
        _ data: Data,
        to destination: URL,
        metadata: StoredMessageMetadata? = nil
    ) throws(MessageStoreError) {
        let destinationPath = destination.path(percentEncoded: false)
        let temporaryPath = url.appending(
            path: Self.temporaryPrefix + UUID().uuidString,
            directoryHint: .notDirectory
        ).path(percentEncoded: false)

        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw .writeFailed(path: destinationPath, reason: Self.describe(errno))
        }
        var renamed = false
        defer {
            if !renamed { unlink(temporaryPath) }
        }
        do {
            defer { close(descriptor) }
            try Self.writeAll(data, to: descriptor, path: destinationPath)
            if let metadata {
                try Self.setMetadata(metadata, descriptor: descriptor, path: destinationPath)
            }
        }
        guard rename(temporaryPath, destinationPath) == 0 else {
            throw .writeFailed(path: destinationPath, reason: Self.describe(errno))
        }
        renamed = true
    }

    // MARK: - Metadata

    /// The metadata stored on a message file, or `.empty` if it is missing or unreadable (e.g. the file was copied
    /// in by hand).
    func metadata(of fileURL: URL) -> StoredMessageMetadata {
        let path = fileURL.path(percentEncoded: false)
        let length = getxattr(path, Self.metadataAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return .empty }
        var buffer = Data(count: length)
        let read = buffer.withUnsafeMutableBytes { bytes in
            getxattr(path, Self.metadataAttribute, bytes.baseAddress, length, 0, XATTR_NOFOLLOW)
        }
        guard read == length else { return .empty }
        return (try? JSONDecoder().decode(StoredMessageMetadata.self, from: buffer)) ?? .empty
    }

    func setMetadata(_ metadata: StoredMessageMetadata, of fileURL: URL) throws(MessageStoreError) {
        let path = fileURL.path(percentEncoded: false)
        let encoded = try Self.encode(metadata, path: path)
        let result = encoded.withUnsafeBytes { bytes in
            setxattr(path, Self.metadataAttribute, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else {
            throw .writeFailed(path: path, reason: Self.describe(errno))
        }
    }

    // MARK: - POSIX helpers

    private static func setMetadata(
        _ metadata: StoredMessageMetadata,
        descriptor: Int32,
        path: String
    ) throws(MessageStoreError) {
        let encoded = try encode(metadata, path: path)
        let result = encoded.withUnsafeBytes { bytes in
            fsetxattr(descriptor, metadataAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else {
            throw .writeFailed(path: path, reason: describe(errno))
        }
    }

    private static func encode(_ metadata: StoredMessageMetadata, path: String) throws(MessageStoreError) -> Data {
        do {
            return try JSONEncoder().encode(metadata)
        } catch {
            throw .writeFailed(path: path, reason: error.localizedDescription)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws(MessageStoreError) {
        let failure: Int32? = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, base + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return nil
        }
        if let failure {
            throw .writeFailed(path: path, reason: describe(failure))
        }
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
