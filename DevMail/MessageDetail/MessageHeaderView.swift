import DevMailCore
import SwiftUI

/// The From, To, Cc, Bcc, Reply-To, Date and Subject of a message.
struct MessageHeaderView: View {
    let message: ParsedMessage
    let summary: MessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.subject ?? "(No Subject)")
                .font(.title2)
                .fontWeight(.semibold)
                .textSelection(.enabled)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                row("From", addresses: from)
                row("To", addresses: message.to.map(\.displayString))
                row("Cc", addresses: message.cc.map(\.displayString))
                row("Bcc", addresses: bcc)
                row("Reply-To", addresses: message.replyTo.map(\.displayString))
                GridRow {
                    label("Date")
                    Text((message.date ?? summary.receivedAt).formatted(date: .long, time: .standard))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var from: [String] {
        if !message.from.isEmpty {
            return message.from.map(\.displayString)
        }
        return summary.envelopeSender.map { [$0] } ?? []
    }

    /// Header Bcc plus envelope recipients missing from every address header, which is how a Bcc'd address
    /// normally arrives.
    private var bcc: [String] {
        message.bcc.map(\.displayString)
            + EnvelopeRecipients.unlisted(summary.envelopeRecipients, in: message)
    }

    @ViewBuilder
    private func row(_ title: String, addresses: [String]) -> some View {
        if !addresses.isEmpty {
            GridRow {
                label(title)
                AddressList(addresses: addresses)
            }
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

/// A comma-separated address list that shows the first few and expands on request, so a message sent to hundreds
/// of recipients doesn't push the body off screen.
private struct AddressList: View {
    let addresses: [String]

    @State private var isExpanded = false

    private static let collapsedCount = 3
    /// Expanded lists longer than this scroll inside a fixed height.
    private static let scrollingCount = 12

    var body: some View {
        if addresses.count <= Self.collapsedCount {
            text(addresses)
        } else if !isExpanded {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                text(Array(addresses.prefix(Self.collapsedCount)))
                Button("and \(addresses.count - Self.collapsedCount) more") {
                    isExpanded = true
                }
                .buttonStyle(.link)
                .fixedSize()
            }
        } else if addresses.count <= Self.scrollingCount {
            text(addresses)
        } else {
            ScrollView {
                text(addresses)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 96)
        }
    }

    private func text(_ addresses: [String]) -> some View {
        Text(addresses.joined(separator: ", "))
            .textSelection(.enabled)
    }
}

nonisolated enum EnvelopeRecipients {
    /// Envelope recipients whose address appears in none of the To, Cc or Bcc headers, compared case-insensitively.
    static func unlisted(_ envelopeRecipients: [String], in message: ParsedMessage) -> [String] {
        let listed = Set((message.to + message.cc + message.bcc).map { normalized($0.address) })
        var seen = Set<String>()
        return envelopeRecipients.filter { recipient in
            let key = normalized(recipient)
            return !key.isEmpty && !listed.contains(key) && seen.insert(key).inserted
        }
    }

    private static func normalized(_ address: String) -> String {
        address
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "<>")))
            .lowercased()
    }
}
