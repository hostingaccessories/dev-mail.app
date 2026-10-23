import AppKit
import Darwin
import DevMailCore
import Foundation

/// The user's settings, persisted in `UserDefaults`.
///
/// Retention limits keep their number while switched off, so turning a limit back on restores the previous value.
struct AppSettings: Equatable {
    enum Key {
        static let host = "SMTPHost"
        static let port = "SMTPPort"
        static let limitsMessageCount = "RetentionLimitsMessageCount"
        static let maxMessageCount = "RetentionMaxMessageCount"
        static let limitsMessageAge = "RetentionLimitsMessageAge"
        static let maxAgeInDays = "RetentionMaxAgeInDays"
        static let showsMenuBarItem = "ShowsMenuBarItem"
        static let hidesDockIcon = "HidesDockIcon"
    }

    static let defaultMaxAgeInDays = 30

    var host: String
    var port: UInt16
    var limitsMessageCount: Bool
    var maxMessageCount: Int
    var limitsMessageAge: Bool
    var maxAgeInDays: Int
    var showsMenuBarItem: Bool

    /// Only takes effect while `showsMenuBarItem` is on, so the app always has a Dock icon or a menu bar item.
    var hidesDockIcon: Bool

    init(
        host: String = SMTPServerConfiguration().host,
        port: UInt16 = SMTPServerConfiguration().port,
        limitsMessageCount: Bool = true,
        maxMessageCount: Int = RetentionPolicy.defaultMaxMessageCount,
        limitsMessageAge: Bool = false,
        maxAgeInDays: Int = Self.defaultMaxAgeInDays,
        showsMenuBarItem: Bool = false,
        hidesDockIcon: Bool = false
    ) {
        self.host = host
        self.port = port
        self.limitsMessageCount = limitsMessageCount
        self.maxMessageCount = maxMessageCount
        self.limitsMessageAge = limitsMessageAge
        self.maxAgeInDays = maxAgeInDays
        self.showsMenuBarItem = showsMenuBarItem
        self.hidesDockIcon = hidesDockIcon
    }

    /// Loads saved settings. Missing or invalid values (for example, edited with `defaults write`) fall back to their
    /// defaults individually.
    init(userDefaults: UserDefaults) {
        let defaults = AppSettings()

        let host = userDefaults.string(forKey: Key.host)
        self.host = host.flatMap { Self.isValidHost($0) ? $0 : nil } ?? defaults.host

        let port = userDefaults.object(forKey: Key.port) as? Int
        self.port = port.flatMap { (1...Int(UInt16.max)).contains($0) ? UInt16($0) : nil } ?? defaults.port

        limitsMessageCount = userDefaults.object(forKey: Key.limitsMessageCount) as? Bool ?? defaults.limitsMessageCount
        maxMessageCount = Self.positive(userDefaults.object(forKey: Key.maxMessageCount)) ?? defaults.maxMessageCount
        limitsMessageAge = userDefaults.object(forKey: Key.limitsMessageAge) as? Bool ?? defaults.limitsMessageAge
        maxAgeInDays = Self.positive(userDefaults.object(forKey: Key.maxAgeInDays)) ?? defaults.maxAgeInDays
        showsMenuBarItem = userDefaults.object(forKey: Key.showsMenuBarItem) as? Bool ?? defaults.showsMenuBarItem
        hidesDockIcon = userDefaults.object(forKey: Key.hidesDockIcon) as? Bool ?? defaults.hidesDockIcon
    }

    func save(to userDefaults: UserDefaults) {
        userDefaults.set(host, forKey: Key.host)
        userDefaults.set(Int(port), forKey: Key.port)
        userDefaults.set(limitsMessageCount, forKey: Key.limitsMessageCount)
        userDefaults.set(maxMessageCount, forKey: Key.maxMessageCount)
        userDefaults.set(limitsMessageAge, forKey: Key.limitsMessageAge)
        userDefaults.set(maxAgeInDays, forKey: Key.maxAgeInDays)
        userDefaults.set(showsMenuBarItem, forKey: Key.showsMenuBarItem)
        userDefaults.set(hidesDockIcon, forKey: Key.hidesDockIcon)
    }

    /// The server configuration for these settings, keeping the other values of `base`.
    func serverConfiguration(base: SMTPServerConfiguration = SMTPServerConfiguration()) -> SMTPServerConfiguration {
        var configuration = base
        configuration.host = host
        configuration.port = port
        return configuration
    }

    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(
            maxMessageCount: limitsMessageCount ? maxMessageCount : nil,
            maxAgeInDays: limitsMessageAge ? maxAgeInDays : nil
        )
    }

    /// No Dock icon only when the menu bar item is there to reach the app instead.
    var activationPolicy: NSApplication.ActivationPolicy {
        Self.activationPolicy(showsMenuBarItem: showsMenuBarItem, hidesDockIcon: hidesDockIcon)
    }

    static func activationPolicy(showsMenuBarItem: Bool, hidesDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showsMenuBarItem && hidesDockIcon ? .accessory : .regular
    }

    private static func positive(_ value: Any?) -> Int? {
        guard let value = value as? Int, value >= 1 else { return nil }
        return value
    }
}

// MARK: - Validation

extension AppSettings {
    /// Parses a port typed by the user. Port 0 (any free port) is not offered: mail clients need a fixed port.
    static func parsePort(_ text: String) -> UInt16? {
        guard let port = UInt16(text.trimmingCharacters(in: .whitespaces)), port >= 1 else { return nil }
        return port
    }

    /// Parses a message count or number of days typed by the user.
    static func parsePositiveInteger(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value >= 1 else { return nil }
        return value
    }

    /// Whether the server can bind `host`: an IPv4 or IPv6 address literal, or `localhost`. Host names other than
    /// `localhost` aren't accepted because the server binds an address, not a name.
    static func isValidHost(_ host: String) -> Bool {
        isLocalhost(host) || ipv4Address(host) != nil || ipv6Address(host) != nil
    }

    /// Whether only this Mac can connect to `host`: `localhost`, 127.0.0.0/8 or ::1 (including 127.0.0.0/8 mapped to
    /// IPv6). Anything else, such as 0.0.0.0 or a LAN address, accepts connections from other devices.
    static func isLoopback(_ host: String) -> Bool {
        if isLocalhost(host) { return true }
        if let address = ipv4Address(host) {
            return UInt32(bigEndian: address.s_addr) >> 24 == 127
        }
        if let address = ipv6Address(host) {
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            let isLoopback = bytes == Array(repeating: 0, count: 15) + [1]
            let isMappedIPv4Loopback =
                bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
                && bytes[12] == 127
            return isLoopback || isMappedIPv4Loopback
        }
        return false
    }

    private static func isLocalhost(_ host: String) -> Bool {
        host.caseInsensitiveCompare("localhost") == .orderedSame
    }

    private static func ipv4Address(_ host: String) -> in_addr? {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1 ? address : nil
    }

    private static func ipv6Address(_ host: String) -> in6_addr? {
        var address = in6_addr()
        return inet_pton(AF_INET6, host, &address) == 1 ? address : nil
    }
}

// MARK: - Applying settings

extension RetentionPolicy {
    /// How many of the messages received at `receivedDates` this policy deletes, mirroring `MessageStore`'s rules.
    func numberOfMessagesRemoved(receivedDates: [Date], now: Date) -> Int {
        let newestFirst = receivedDates.sorted(by: >)
        let keptByCount = maxMessageCount.map { max($0, 1) } ?? newestFirst.count
        let cutoff = maxAgeInDays.map { now.addingTimeInterval(-Double(max($0, 1)) * 86_400) }
        return newestFirst.enumerated().count { index, receivedAt in
            index >= keptByCount || cutoff.map { receivedAt < $0 } ?? false
        }
    }
}

extension AppModel {
    /// Restarts the server on `host` and `port` unless it is already configured for them. Returns whether it
    /// restarted.
    @discardableResult
    func applyServerAddress(host: String, port: UInt16) async -> Bool {
        guard host != serverConfiguration.host || port != serverConfiguration.port else { return false }
        var configuration = serverConfiguration
        configuration.host = host
        configuration.port = port
        await restartServer(with: configuration)
        return true
    }
}
