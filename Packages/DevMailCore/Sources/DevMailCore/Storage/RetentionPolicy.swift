import Foundation

/// Limits that stop a busy app filling the disk with test mail.
public struct RetentionPolicy: Sendable, Equatable, Codable {
    public static let defaultMaxMessageCount = 1_000

    /// Keep at most this many messages, deleting the oldest first. `nil` disables the limit; values below 1 are
    /// treated as 1.
    public var maxMessageCount: Int?

    /// Delete messages received more than this many days ago. `nil` disables the limit; values below 1 are treated
    /// as 1.
    public var maxAgeInDays: Int?

    public init(maxMessageCount: Int? = Self.defaultMaxMessageCount, maxAgeInDays: Int? = nil) {
        self.maxMessageCount = maxMessageCount
        self.maxAgeInDays = maxAgeInDays
    }

    /// No limits at all.
    public static let unlimited = Self(maxMessageCount: nil, maxAgeInDays: nil)

    /// IDs of the messages this policy removes, given summaries and the current time. Age is measured from
    /// `receivedAt` because the `Date` header is supplied by the sender and may be wrong.
    func expiredMessageIDs(in summaries: some Collection<MessageSummary>, now: Date) -> Set<UUID> {
        var expired = Set<UUID>()
        if let maxAgeInDays {
            let cutoff = now.addingTimeInterval(-Double(max(maxAgeInDays, 1)) * 86_400)
            for summary in summaries where summary.receivedAt < cutoff {
                expired.insert(summary.id)
            }
        }
        if let maxMessageCount {
            let newestFirst = summaries.sorted(by: MessageSummary.newestFirst)
            for summary in newestFirst.dropFirst(max(maxMessageCount, 1)) {
                expired.insert(summary.id)
            }
        }
        return expired
    }
}

extension MessageSummary {
    /// Orders by `receivedAt` descending, breaking ties by ID so the order is stable.
    public static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}
