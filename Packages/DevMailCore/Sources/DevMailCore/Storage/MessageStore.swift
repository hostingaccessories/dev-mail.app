import Foundation

/// A change to the stored messages, delivered to observers of `MessageStore.changes()`.
public enum MessageStoreChange: Sendable, Equatable {
    case added(MessageSummary)
    case updated(MessageSummary)
    case removed(Set<UUID>)
}

/// Persists received messages as raw `.eml` files with a JSON index for fast listing.
///
/// The `.eml` files are the source of truth. Envelope and read state live in an extended attribute on each file, so
/// the index (`index.json`) is only a cache: it is rebuilt when missing or corrupt and reconciled with the folder
/// contents every time the store is opened.
public actor MessageStore {
    /// `~/Library/Application Support/Dev Mail/Messages/`.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Dev Mail/Messages", directoryHint: .isDirectory)
    }

    nonisolated public let directory: URL
    public private(set) var retentionPolicy: RetentionPolicy

    private let files: MessageDirectory
    private let now: @Sendable () -> Date
    private var entries: [UUID: MessageSummary] = [:]
    private var observers: [UUID: AsyncStream<MessageStoreChange>.Continuation] = [:]

    /// Opens the store in `directory`, creating it if needed, loading or rebuilding the index and applying the
    /// retention policy.
    ///
    /// - Parameter now: The clock used for age-based retention; injectable for tests.
    public init(
        directory: URL,
        retentionPolicy: RetentionPolicy = RetentionPolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws(MessageStoreError) {
        self.directory = directory
        self.retentionPolicy = retentionPolicy
        self.files = MessageDirectory(url: directory)
        self.now = now

        try files.prepare()
        files.removeStaleTemporaryFiles()
        try loadIndex()
        applyRetention()
    }

    // MARK: - Reading

    /// All messages, newest first.
    public func summaries() -> [MessageSummary] {
        entries.values.sorted(by: MessageSummary.newestFirst)
    }

    /// Messages whose subject, sender or recipients contain `query` (case- and diacritic-insensitive), newest
    /// first. An empty query matches everything.
    public func summaries(matching query: String) -> [MessageSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return summaries() }
        return entries.values.filter { $0.matches(trimmed) }.sorted(by: MessageSummary.newestFirst)
    }

    public func summary(for id: UUID) -> MessageSummary? {
        entries[id]
    }

    /// The original message bytes.
    public func rawData(for id: UUID) throws(MessageStoreError) -> Data {
        try files.read(fileURL(for: id))
    }

    public func parsedMessage(for id: UUID) throws(MessageStoreError) -> ParsedMessage {
        MIMEParser.parse(try rawData(for: id))
    }

    /// Location of the message's `.eml` file, for "Open in Mail" or "Show in Finder".
    public func fileURL(for id: UUID) throws(MessageStoreError) -> URL {
        guard let entry = entries[id] else { throw .messageNotFound(id) }
        return files.fileURL(id: entry.id, receivedAt: entry.receivedAt)
    }

    // MARK: - Writing

    /// Saves a message, indexes it and applies the retention policy.
    @discardableResult
    public func add(_ message: ReceivedMessage) throws(MessageStoreError) -> MessageSummary {
        guard entries[message.id] == nil else { throw .duplicateMessage(message.id) }

        // Truncate to the precision stored in the file name so a rebuilt index matches exactly.
        let millis = (message.receivedAt.timeIntervalSince1970 * 1_000).rounded(.down)
        let receivedAt = Date(timeIntervalSince1970: millis / 1_000)
        let metadata = StoredMessageMetadata(
            envelopeSender: message.envelopeSender,
            envelopeRecipients: message.recipients,
            isRead: false
        )
        try files.writeAtomically(
            message.data,
            to: files.fileURL(id: message.id, receivedAt: receivedAt),
            metadata: metadata
        )

        let summary = MessageSummary(id: message.id, receivedAt: receivedAt, data: message.data, metadata: metadata)
        entries[summary.id] = summary
        saveIndex()
        notify(.added(summary))
        applyRetention()
        return summary
    }

    public func setRead(_ isRead: Bool, for id: UUID) throws(MessageStoreError) {
        guard var entry = entries[id] else { throw .messageNotFound(id) }
        guard entry.isRead != isRead else { return }

        let url = files.fileURL(id: entry.id, receivedAt: entry.receivedAt)
        var metadata = files.metadata(of: url)
        metadata.isRead = isRead
        try files.setMetadata(metadata, of: url)

        entry.isRead = isRead
        entries[id] = entry
        saveIndex()
        notify(.updated(entry))
    }

    /// Deletes the given messages. Unknown IDs are ignored. If a file cannot be deleted, the rest are still
    /// removed and the first error is thrown afterwards.
    public func delete(ids: some Sequence<UUID>) throws(MessageStoreError) {
        let result = remove(Set(ids))
        if let error = result.firstError { throw error }
    }

    public func deleteAll() throws(MessageStoreError) {
        try delete(ids: Array(entries.keys))
    }

    /// Replaces the retention policy and applies it immediately.
    public func updateRetentionPolicy(_ policy: RetentionPolicy) {
        retentionPolicy = policy
        applyRetention()
    }

    // MARK: - Observation

    /// A stream of changes made after this call. Each call returns an independent stream; it finishes when the
    /// consuming task is cancelled.
    public func changes() -> AsyncStream<MessageStoreChange> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: MessageStoreChange.self,
            bufferingPolicy: .unbounded
        )
        let token = UUID()
        observers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token) }
        }
        return stream
    }

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func notify(_ change: MessageStoreChange) {
        for continuation in observers.values {
            continuation.yield(change)
        }
    }

    // MARK: - Index

    private struct IndexFile: Codable {
        static let currentVersion = 1

        var version: Int
        var messages: [MessageSummary]
    }

    /// Loads the index, falling back to an empty one if it is missing, corrupt or from another version, then
    /// reconciles it with the files on disk: entries without a file are dropped and unindexed files are parsed.
    private func loadIndex() throws(MessageStoreError) {
        let onDisk = try files.messageFiles()
        let decoded = (try? Data(contentsOf: files.indexURL))
            .flatMap { try? JSONDecoder().decode(IndexFile.self, from: $0) }
            .flatMap { $0.version == IndexFile.currentVersion ? $0.messages : nil }

        var changed = decoded == nil
        for entry in decoded ?? [] {
            if let file = onDisk[entry.id], file.receivedAt == entry.receivedAt {
                entries[entry.id] = entry
            } else {
                changed = true
            }
        }
        for file in onDisk.values where entries[file.id] == nil {
            // An unreadable file is skipped rather than failing the whole store; it stays on disk untouched.
            guard let data = try? files.read(file.url) else { continue }
            let metadata = files.metadata(of: file.url)
            entries[file.id] = MessageSummary(id: file.id, receivedAt: file.receivedAt, data: data, metadata: metadata)
            changed = true
        }
        if changed { saveIndex() }
    }

    /// Writes the index. Failure is deliberately ignored: the index is a cache that `loadIndex()` reconciles with
    /// the `.eml` files on the next launch, and the in-memory state stays correct meanwhile.
    private func saveIndex() {
        let index = IndexFile(version: IndexFile.currentVersion, messages: summaries())
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? files.writeAtomically(data, to: files.indexURL)
    }

    // MARK: - Removal

    private func applyRetention() {
        let expired = retentionPolicy.expiredMessageIDs(in: entries.values, now: now())
        // Retention runs in the background of other operations; a file that cannot be deleted now is retried on
        // the next add or launch.
        _ = remove(expired)
    }

    /// Deletes each message's file and index entry together. An entry is kept if its file could not be deleted.
    private func remove(_ ids: Set<UUID>) -> (removed: Set<UUID>, firstError: MessageStoreError?) {
        var removed = Set<UUID>()
        var firstError: MessageStoreError?
        for id in ids {
            guard let entry = entries[id] else { continue }
            do throws(MessageStoreError) {
                try files.remove(files.fileURL(id: entry.id, receivedAt: entry.receivedAt))
                entries[id] = nil
                removed.insert(id)
            } catch {
                firstError = firstError ?? error
            }
        }
        if !removed.isEmpty {
            saveIndex()
            notify(.removed(removed))
        }
        return (removed, firstError)
    }
}
