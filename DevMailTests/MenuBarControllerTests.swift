import AppKit
import DevMailCore
import Testing

@testable import DevMail

struct MenuBarControllerTests {
    // MARK: - Symbol

    @Test func symbolForEachState() {
        #expect(MenuBarController.symbolName(for: .listening(host: "127.0.0.1", port: 1025)) == "envelope")
        #expect(MenuBarController.symbolName(for: .stopped) == "envelope")
        #expect(MenuBarController.symbolName(for: .failed(.addressInUse(port: 1025))) == "exclamationmark.triangle")
    }

    @Test(arguments: [
        SMTPServer.State.listening(host: "127.0.0.1", port: 1025),
        .stopped,
        .failed(.addressInUse(port: 1025)),
        .failed(.permissionDenied(port: 25)),
        .failed(.listenerFailed(reason: "test")),
    ])
    @MainActor
    func symbolExists(for state: SMTPServer.State) {
        let name = MenuBarController.symbolName(for: state)
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
    }

    // MARK: - Address

    @Test func addressLabelForIPv4() {
        #expect(MenuBarController.addressLabel(host: "127.0.0.1", port: 1025) == "127.0.0.1:1025")
        #expect(MenuBarController.addressLabel(host: "0.0.0.0", port: 25) == "0.0.0.0:25")
    }

    @Test func addressLabelBracketsIPv6() {
        #expect(MenuBarController.addressLabel(host: "::1", port: 1025) == "[::1]:1025")
        #expect(MenuBarController.addressLabel(host: "::", port: 2525) == "[::]:2525")
        #expect(MenuBarController.addressLabel(host: "fe80::1", port: 65_535) == "[fe80::1]:65535")
    }

    @Test func addressLabelKeepsExistingBrackets() {
        #expect(MenuBarController.addressLabel(host: "[::1]", port: 1025) == "[::1]:1025")
    }
}
