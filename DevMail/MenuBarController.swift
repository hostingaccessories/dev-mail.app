import AppKit
import DevMailCore
import Observation
import SwiftUI

/// Shows the server status in the menu bar while the "Show in menu bar" setting is on. A left click opens the Mail
/// window; a right click (or Control-click) shows a menu with a server toggle, Mail, Settings and Quit.
///
/// Uses `NSStatusItem` rather than SwiftUI's `MenuBarExtra`, which can't tell left and right clicks apart. Owned by
/// the app delegate so it keeps working with the window closed.
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let menuWidth: CGFloat = 260

    private let model: AppModel
    private let onOpenMail: () -> Void
    private let onOpenSettings: () -> Void
    private var isStarted = false
    private var statusItem: NSStatusItem?
    private lazy var menu = makeMenu()
    private var serverRowView: NSView?

    init(model: AppModel, onOpenMail: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onOpenMail = onOpenMail
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        update()
    }

    // MARK: - Pure helpers

    /// The SF Symbol shown in the menu bar for `state`. Stopped uses the listening symbol, dimmed.
    nonisolated static func symbolName(for state: SMTPServer.State) -> String {
        switch state {
        case .listening, .stopped: "envelope"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// `host:port`, with IPv6 hosts in brackets so the port is unambiguous.
    nonisolated static func addressLabel(host: String, port: UInt16) -> String {
        let isIPv6 = host.contains(":") && !host.hasPrefix("[")
        return isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    // MARK: - Observation

    private func update() {
        // `onChange` fires once, before the change is applied, so re-read and re-register on the next main-actor turn.
        let (showsMenuBarItem, state) = withObservationTracking {
            // Read the configuration too, so the item refreshes when the address changes.
            _ = model.serverConfiguration
            return (model.showsMenuBarItem, model.serverState)
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }

        guard showsMenuBarItem else {
            removeStatusItem()
            return
        }
        let statusItem = statusItem ?? makeStatusItem()
        configure(statusItem.button, for: state)
    }

    // MARK: - Status item

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        return item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func configure(_ button: NSStatusBarButton?, for state: SMTPServer.State) {
        guard let button else { return }
        let image = NSImage(
            systemSymbolName: Self.symbolName(for: state),
            accessibilityDescription: "Dev Mail: \(state.statusText)"
        )
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !state.isListening
        button.toolTip = state.statusText
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            onOpenMail()
            return
        }
        let isControlClick = event.type == .leftMouseUp && event.modifierFlags.contains(.control)
        if event.type == .rightMouseUp || isControlClick {
            showMenu(from: sender)
        } else {
            onOpenMail()
        }
    }

    /// Attaches the menu just long enough to open it, so left clicks keep reaching `statusItemClicked`.
    private func showMenu(from button: NSStatusBarButton) {
        guard let statusItem else { return }
        statusItem.menu = menu
        button.performClick(nil)
    }

    /// The row's height depends on the status text (an error can wrap), so fit it each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        guard let serverRowView else { return }
        serverRowView.setFrameSize(NSSize(width: Self.menuWidth, height: serverRowView.fittingSize.height))
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let hostingView = NSHostingView(rootView: MenuBarServerRow().environment(model))
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.menuWidth, height: hostingView.fittingSize.height)
        let serverItem = NSMenuItem()
        serverItem.view = hostingView
        serverRowView = hostingView
        menu.addItem(serverItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("Mail", action: #selector(openMail), keyEquivalent: "0"))
        menu.addItem(menuItem("Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Dev Mail", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func openMail() {
        onOpenMail()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
