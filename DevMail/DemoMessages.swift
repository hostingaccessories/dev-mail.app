import DevMailCore
import Foundation

enum DemoMessagesError: Error, LocalizedError {
    /// The app bundle has no demo messages, which means it was built without them.
    case missing

    /// A bundled message isn't valid UTF-8.
    case unreadable(fileName: String)

    var errorDescription: String? {
        switch self {
        case .missing: "The demo messages are missing from the app."
        case .unreadable(let fileName): "The demo message \(fileName) couldn't be read."
        }
    }
}

/// Sample messages bundled in `DemoMessages/` for trying the app out and for QA: HTML and plain text, attachments,
/// inline and remote images, encoded headers and Laravel mail.
enum DemoMessages {
    /// Time between consecutive messages, so they list in file name order.
    private static let spacing: TimeInterval = 7 * 60

    /// The bundled messages in file name order, the first received at `now` and each next one `spacing` earlier.
    ///
    /// The files have no `Date` header; one is added to match the received time so the dates always look current.
    static func messages(now: Date = .now, bundle: Bundle = .main) throws -> [ReceivedMessage] {
        let urls = (bundle.urls(forResourcesWithExtension: "eml", subdirectory: "DemoMessages") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { throw DemoMessagesError.missing }

        return try urls.enumerated().map { index, url in
            let receivedAt = now - Double(index) * spacing
            guard let source = String(bytes: try Data(contentsOf: url), encoding: .utf8) else {
                throw DemoMessagesError.unreadable(fileName: url.lastPathComponent)
            }
            let raw = "Date: \(rfc5322Date(receivedAt))\n\(source)"
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
            return ReceivedMessage(
                envelopeSender: "bounce@demo.test",
                recipients: ["you@example.com"],
                data: Data(raw.utf8),
                receivedAt: receivedAt
            )
        }
    }

    private static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
