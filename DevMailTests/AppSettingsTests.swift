import DevMailCore
import Foundation
import Testing

@testable import DevMail

/// Uses a throwaway `UserDefaults` suite per test so the app's real settings are never read or changed.
@MainActor
struct AppSettingsTests {
    private let suiteName = "DevMailTests-\(UUID().uuidString)"

    // MARK: - Persistence

    @Test func defaultsWhenNothingSaved() throws {
        try withUserDefaults { userDefaults in
            let settings = AppSettings(userDefaults: userDefaults)
            #expect(settings == AppSettings())
            #expect(settings.host == "127.0.0.1")
            #expect(settings.port == 1025)
            #expect(settings.retentionPolicy == RetentionPolicy())
            #expect(settings.retentionPolicy.maxMessageCount == 1000)
            #expect(settings.retentionPolicy.maxAgeInDays == nil)
        }
    }

    @Test func savesAndLoads() throws {
        try withUserDefaults { userDefaults in
            let settings = AppSettings(
                host: "::1",
                port: 2525,
                limitsMessageCount: false,
                maxMessageCount: 50,
                limitsMessageAge: true,
                maxAgeInDays: 7
            )
            settings.save(to: userDefaults)

            #expect(AppSettings(userDefaults: userDefaults) == settings)
            #expect(userDefaults.string(forKey: AppSettings.Key.host) == "::1")
            #expect(userDefaults.integer(forKey: AppSettings.Key.port) == 2525)
        }
    }

    @Test func ignoresInvalidSavedValues() throws {
        try withUserDefaults { userDefaults in
            userDefaults.set("mail.example.com", forKey: AppSettings.Key.host)
            userDefaults.set(70_000, forKey: AppSettings.Key.port)
            userDefaults.set(0, forKey: AppSettings.Key.maxMessageCount)
            userDefaults.set("seven", forKey: AppSettings.Key.maxAgeInDays)
            userDefaults.set(true, forKey: AppSettings.Key.limitsMessageAge)

            let settings = AppSettings(userDefaults: userDefaults)
            #expect(settings.host == "127.0.0.1")
            #expect(settings.port == 1025)
            #expect(settings.maxMessageCount == RetentionPolicy.defaultMaxMessageCount)
            #expect(settings.maxAgeInDays == AppSettings.defaultMaxAgeInDays)
            #expect(settings.limitsMessageAge)
        }
    }

    // MARK: - Conversion

    @Test func convertsToServerConfiguration() {
        let base = SMTPServerConfiguration(maxConnections: 4, maxMessageSize: 1024)
        let configuration = AppSettings(host: "0.0.0.0", port: 2525).serverConfiguration(base: base)
        #expect(configuration.host == "0.0.0.0")
        #expect(configuration.port == 2525)
        #expect(configuration.maxConnections == 4)
        #expect(configuration.maxMessageSize == 1024)
    }

    @Test func convertsToRetentionPolicy() {
        let both = AppSettings(limitsMessageCount: true, maxMessageCount: 10, limitsMessageAge: true, maxAgeInDays: 3)
        #expect(both.retentionPolicy == RetentionPolicy(maxMessageCount: 10, maxAgeInDays: 3))

        let neither = AppSettings(limitsMessageCount: false, maxMessageCount: 10, limitsMessageAge: false)
        #expect(neither.retentionPolicy == .unlimited)
    }

    // MARK: - Validation

    @Test(
        arguments: [
            ("1", 1), ("1025", 1025), (" 2525 ", 2525), ("65535", 65535),
        ] as [(String, UInt16)]
    )
    func acceptsPort(text: String, port: UInt16) {
        #expect(AppSettings.parsePort(text) == port)
    }

    @Test(arguments: ["", "0", "-1", "65536", "99999999999999999999", "25.5", "abc", "1 025"])
    func rejectsPort(text: String) {
        #expect(AppSettings.parsePort(text) == nil)
    }

    @Test func parsesPositiveIntegers() {
        #expect(AppSettings.parsePositiveInteger("1") == 1)
        #expect(AppSettings.parsePositiveInteger(" 500 ") == 500)
        #expect(AppSettings.parsePositiveInteger("0") == nil)
        #expect(AppSettings.parsePositiveInteger("-3") == nil)
        #expect(AppSettings.parsePositiveInteger("ten") == nil)
    }

    @Test(arguments: [
        "127.0.0.1", "127.1.2.3", "localhost", "LocalHost", "::1", "::ffff:127.0.0.1",
    ])
    func loopbackHosts(host: String) {
        #expect(AppSettings.isValidHost(host))
        #expect(AppSettings.isLoopback(host))
    }

    @Test(arguments: ["0.0.0.0", "192.168.1.20", "10.0.0.5", "::", "fe80::1", "2001:db8::1", "128.0.0.1"])
    func networkHosts(host: String) {
        #expect(AppSettings.isValidHost(host))
        #expect(!AppSettings.isLoopback(host))
    }

    @Test(arguments: ["", "example.com", "256.0.0.1", "127.0.0", "1.2.3.4.5", "::1::", "localhost.localdomain"])
    func invalidHosts(host: String) {
        #expect(!AppSettings.isValidHost(host))
        #expect(!AppSettings.isLoopback(host))
    }

    // MARK: - Retention preview

    @Test func countsMessagesRemovedByPolicy() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let dates = (0..<5).map { now.addingTimeInterval(-Double($0) * 86_400 - 60) }  // 0 to 4 days old

        #expect(RetentionPolicy.unlimited.numberOfMessagesRemoved(receivedDates: dates, now: now) == 0)
        #expect(RetentionPolicy(maxMessageCount: 5).numberOfMessagesRemoved(receivedDates: dates, now: now) == 0)
        #expect(RetentionPolicy(maxMessageCount: 2).numberOfMessagesRemoved(receivedDates: dates, now: now) == 3)
        #expect(
            RetentionPolicy(maxMessageCount: nil, maxAgeInDays: 2).numberOfMessagesRemoved(
                receivedDates: dates,
                now: now
            ) == 3
        )
        // Overlapping limits count each message once.
        #expect(
            RetentionPolicy(maxMessageCount: 4, maxAgeInDays: 3).numberOfMessagesRemoved(
                receivedDates: dates,
                now: now
            ) == 2
        )
    }

    // MARK: - Helpers

    private func withUserDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        try body(userDefaults)
    }
}
