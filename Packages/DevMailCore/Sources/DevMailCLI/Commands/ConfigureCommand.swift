import ArgumentParser
import DevMailCore
import Foundation

struct ConfigureCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Show or change Dev Mail's settings.",
        discussion: """
            With no options, shows the settings. Changes apply right away, as in Dev Mail's Settings window: changing \
            the host or port restarts the server, and tighter retention limits delete messages outside them.
            """
    )

    @Option(help: "The address to listen on: an IPv4 or IPv6 address, or localhost.")
    var host: String?

    @Option(help: "The port to listen on.")
    var port: UInt16?

    @Flag(help: "Restore the default host and port.")
    var resetServer = false

    @Option(name: .customLong("max-messages"), help: "Keep only this many recent messages, or 'off' for no limit.")
    var maxMessages: Limit?

    @Option(name: .customLong("max-age-days"), help: "Delete messages older than this many days, or 'off'.")
    var maxAgeDays: Limit?

    @Option(name: .customLong("menu-bar"), help: "Show Dev Mail in the menu bar: on or off.")
    var menuBar: Switch?

    @Option(
        name: .customLong("dock-icon"),
        help: "Show the Dock icon: on or off. It's only hidden while the menu bar item is on."
    )
    var dockIcon: Switch?

    @Option(name: .customLong("open-at-login"), help: "Open Dev Mail at login: on or off.")
    var openAtLogin: Switch?

    @Flag(name: .shortAndLong, help: "Don't ask before a retention change deletes messages.")
    var yes = false

    @Flag(help: "Print the settings as JSON.")
    var json = false

    func validate() throws {
        if resetServer, host != nil || port != nil {
            throw ValidationError("Use --reset-server or --host and --port, not both.")
        }
        if port == 0 {
            throw ValidationError("--port must be from 1 to 65535.")
        }
    }

    /// The settings to change; empty when only showing them.
    var patch: ControlSettingsPatch {
        var patch = ControlSettingsPatch(host: host, port: port)
        if resetServer {
            let defaults = SMTPServerConfiguration()
            patch.host = defaults.host
            patch.port = defaults.port
        }
        switch maxMessages {
        case .limit(let count):
            patch.limitsMessageCount = true
            patch.maxMessageCount = count
        case .off:
            patch.limitsMessageCount = false
        case nil:
            break
        }
        switch maxAgeDays {
        case .limit(let days):
            patch.limitsMessageAge = true
            patch.maxAgeInDays = days
        case .off:
            patch.limitsMessageAge = false
        case nil:
            break
        }
        patch.showsMenuBarItem = menuBar?.isOn
        patch.hidesDockIcon = dockIcon.map { !$0.isOn }
        patch.opensAtLogin = openAtLogin?.isOn
        return patch
    }

    func run(with context: CommandContext) throws {
        let patch = patch
        let settings: ControlSettings
        if patch.isEmpty {
            guard case .settings(let current) = try context.connection.sendExpectingSuccess(.getSettings) else {
                throw CLIError.unexpectedResponse
            }
            settings = current
        } else {
            settings = try update(patch, context: context)
        }

        context.print(json ? try JSONOutput.string(settings) : AppFormatting(style: context.style).settings(settings))
        if patch.host != nil || patch.port != nil {
            try checkServer(context: context)
        }
    }

    /// Applies the patch, asking first if it would delete messages.
    private func update(_ patch: ControlSettingsPatch, context: CommandContext) throws -> ControlSettings {
        var response = try context.connection.sendExpectingSuccess(.updateSettings(patch, confirmDeletion: yes))
        if case .confirmationRequired(let count) = response {
            let messages = count == 1 ? "1 message" : "\(count) messages"
            guard let confirm = context.confirm else {
                throw CLIError("This would delete \(messages). Pass --yes to apply it anyway.")
            }
            guard confirm("This deletes \(messages) right away. Continue?") else {
                throw CLIError("Settings not changed.")
            }
            response = try context.connection.sendExpectingSuccess(.updateSettings(patch, confirmDeletion: true))
        }
        guard case .settings(let settings) = response else { throw CLIError.unexpectedResponse }
        return settings
    }

    /// A new address is saved even if the server can't listen on it, so say when that happened.
    private func checkServer(context: CommandContext) throws {
        guard case .status(let status) = try context.connection.sendExpectingSuccess(.serverStatus),
            status.state == .failed
        else { return }
        throw CLIError("Settings saved, but the server couldn't start: \(status.failureReason ?? "unknown error")")
    }
}

/// A retention limit: a positive number, or `off`.
enum Limit: ExpressibleByArgument, Equatable {
    case limit(Int)
    case off

    init?(argument: String) {
        if argument.lowercased() == "off" {
            self = .off
        } else if let value = Int(argument), value >= 1 {
            self = .limit(value)
        } else {
            return nil
        }
    }

    static var defaultCompletionKind: CompletionKind { .list(["off"]) }
}

/// An on/off setting.
enum Switch: String, ExpressibleByArgument, CaseIterable {
    // swiftlint:disable:next identifier_name
    case on, off

    init?(argument: String) {
        switch argument.lowercased() {
        case "on", "yes", "true": self = .on
        case "off", "no", "false": self = .off
        default: return nil
        }
    }

    var isOn: Bool { self == .on }
}
