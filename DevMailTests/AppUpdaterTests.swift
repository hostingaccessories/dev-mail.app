import Foundation
import Testing

@testable import DevMail

@MainActor
struct AppUpdaterTests {
    @Test func infoPlistPointsAtAppcast() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        #expect(feedURL == "https://dev-mail.hostingaccessories.com/appcast.xml")
    }

    @Test func requiresPublicEDKey() {
        #expect(!AppUpdater.hasPublicEDKey(nil))
        #expect(!AppUpdater.hasPublicEDKey([:]))
        #expect(!AppUpdater.hasPublicEDKey(["SUPublicEDKey": ""]))
        #expect(!AppUpdater.hasPublicEDKey(["SUPublicEDKey": "  "]))
        #expect(AppUpdater.hasPublicEDKey(["SUPublicEDKey": "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="]))
    }

    @Test func idleUpdaterCannotCheck() {
        let updater = AppUpdater(startingUpdater: false)
        #expect(!updater.canCheckForUpdates)
    }
}
