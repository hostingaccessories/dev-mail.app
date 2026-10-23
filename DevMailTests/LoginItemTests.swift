import Foundation
import ServiceManagement
import Testing

@testable import DevMail

/// Stands in for `SMAppService.mainApp` so tests never change the real login items.
@MainActor
final class FakeLoginItem: LoginItem {
    struct Failure: Error {}

    var status: SMAppService.Status
    var fails = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if fails { throw Failure() }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if fails { throw Failure() }
        status = .notRegistered
    }
}

@MainActor
struct LoginItemTests {
    @Test(arguments: [
        (SMAppService.Status.notRegistered, false, false),
        (.notFound, false, false),
        (.enabled, true, false),
        (.requiresApproval, true, true),
    ])
    func readsStatus(status: SMAppService.Status, isEnabled: Bool, requiresApproval: Bool) {
        let setting = OpenAtLoginSetting(loginItem: FakeLoginItem(status: status))
        #expect(setting.isEnabled == isEnabled)
        #expect(setting.requiresApproval == requiresApproval)
    }

    @Test func enablesAndDisables() {
        let loginItem = FakeLoginItem()
        let setting = OpenAtLoginSetting(loginItem: loginItem)

        setting.setEnabled(true)
        #expect(setting.isEnabled)
        #expect(loginItem.registerCount == 1)

        setting.setEnabled(false)
        #expect(!setting.isEnabled)
        #expect(loginItem.unregisterCount == 1)
        #expect(setting.errorMessage == nil)
    }

    @Test func revertsWhenRegisteringFails() {
        let loginItem = FakeLoginItem()
        loginItem.fails = true
        let setting = OpenAtLoginSetting(loginItem: loginItem)

        setting.setEnabled(true)
        #expect(!setting.isEnabled)
        #expect(setting.errorMessage != nil)

        loginItem.fails = false
        setting.setEnabled(true)
        #expect(setting.isEnabled)
        #expect(setting.errorMessage == nil)
    }

    @Test func picksUpChangesMadeInSystemSettings() {
        let loginItem = FakeLoginItem(status: .enabled)
        let setting = OpenAtLoginSetting(loginItem: loginItem)

        loginItem.status = .notRegistered
        setting.refresh()
        #expect(!setting.isEnabled)
    }

    @Test func doesNotUnregisterWhenNotRegistered() {
        let loginItem = FakeLoginItem(status: .notFound)
        let setting = OpenAtLoginSetting(loginItem: loginItem)

        setting.setEnabled(false)
        #expect(loginItem.unregisterCount == 0)
        #expect(setting.errorMessage == nil)
    }
}
