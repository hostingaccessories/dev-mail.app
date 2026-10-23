import DevMailCore
import Foundation

/// Renders the server status and settings as aligned `Label: value` lines.
struct AppFormatting {
    var style: TerminalStyle

    func status(_ status: ControlServerStatus) -> String {
        let address = Self.address(host: status.host, port: status.port)
        let server =
            switch status.state {
            case .listening: "listening on \(address)"
            case .stopped: "stopped (\(address))"
            case .failed: "failed on \(address): \(status.failureReason ?? "unknown error")"
            }
        return fields([
            ("Server", server),
            ("Messages", "\(status.messageCount) (\(status.unreadCount) unread)"),
            ("Folder", (status.messagesDirectory as NSString).abbreviatingWithTildeInPath),
        ])
    }

    func settings(_ settings: ControlSettings) -> String {
        let dockIcon: String
        if !settings.hidesDockIcon {
            dockIcon = "shown"
        } else if settings.showsMenuBarItem {
            dockIcon = "hidden"
        } else {
            dockIcon = "shown (hidden only while the menu bar item is on)"
        }
        let keep = settings.limitsMessageCount ? "the most recent \(settings.maxMessageCount) messages" : "all messages"
        return fields([
            ("Host", settings.host),
            ("Port", String(settings.port)),
            ("Keep", keep),
            ("Delete after", settings.limitsMessageAge ? Self.days(settings.maxAgeInDays) : "never"),
            ("Menu bar item", settings.showsMenuBarItem ? "on" : "off"),
            ("Dock icon", dockIcon),
            ("Open at login", settings.opensAtLogin ? "on" : "off"),
        ])
    }

    private func fields(_ fields: [(String, String)]) -> String {
        let width = (fields.map(\.0.count).max() ?? 0) + 1
        return fields.map { label, value in
            style.bold((label + ":").padding(toLength: width, withPad: " ", startingAt: 0)) + " " + value
        }.joined(separator: "\n")
    }

    /// `host:port`, with IPv6 addresses in brackets.
    static func address(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }
}
