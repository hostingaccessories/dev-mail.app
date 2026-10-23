import DevMailCore
import Foundation
import SwiftUI

// MARK: - Row presentation

extension MessageSummary {
    /// The sender's display name, else their address, else the envelope sender.
    var senderDisplayName: String {
        if let name = sender?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let address = sender?.address, !address.isEmpty {
            return address
        }
        if let envelopeSender, !envelopeSender.isEmpty {
            return envelopeSender
        }
        return "(Unknown Sender)"
    }

    var displaySubject: String {
        guard let subject, !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "(No Subject)"
        }
        return subject
    }
}

/// How a message's date is shown in the list: the time for today's messages, otherwise the date.
enum MessageDateStyle: Equatable {
    case time
    case date

    init(for date: Date, now: Date = .now, calendar: Calendar = .current) {
        self = calendar.isDate(date, inSameDayAs: now) ? .time : .date
    }

    var formatStyle: Date.FormatStyle {
        switch self {
        case .time: Date.FormatStyle(date: .omitted, time: .shortened)
        case .date: Date.FormatStyle(date: .numeric, time: .omitted)
        }
    }
}

// MARK: - Selection

enum MessageListSelection {
    /// The message to select after deleting `deleted` from the list `ids`: the first remaining message below the last
    /// deleted one, else the nearest one above. `nil` when nothing remains or none of `deleted` is in the list.
    static func neighbour(afterDeleting deleted: Set<UUID>, in ids: [UUID]) -> UUID? {
        guard let firstIndex = ids.firstIndex(where: deleted.contains),
            let lastIndex = ids.lastIndex(where: deleted.contains)
        else { return nil }
        if let below = ids[(lastIndex + 1)...].first(where: { !deleted.contains($0) }) {
            return below
        }
        return ids[..<firstIndex].last { !deleted.contains($0) }
    }

    /// Whether a read toggle on `ids` should mark them read (any is unread) rather than unread.
    static func shouldMarkRead(_ ids: Set<UUID>, in summaries: [MessageSummary]) -> Bool {
        summaries.contains { ids.contains($0.id) && !$0.isRead }
    }
}

extension AppModel {
    /// Marks each of `ids` that is still stored and not already in that state.
    func setRead(_ isRead: Bool, ids: Set<UUID>) async {
        let targets = summaries.filter { ids.contains($0.id) && $0.isRead != isRead }.map(\.id)
        for id in targets {
            await markRead(id, isRead: isRead)
        }
    }
}

// MARK: - Menu bar integration

extension FocusedValues {
    /// The main window's message selection, for the Message menu.
    @Entry var messageSelection: Binding<Set<MessageSummary.ID>>?

    /// Presents the main window's Delete All confirmation.
    @Entry var isConfirmingClearAll: Binding<Bool>?

    /// Whether the selected message's headers panel is open, for the View menu.
    @Entry var showsHeaders: Binding<Bool>?
}
