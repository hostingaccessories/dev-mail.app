import ArgumentParser
import DevMailCore
import Foundation

struct ServerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Start, stop or check Dev Mail's SMTP server.",
        subcommands: [Start.self, Stop.self, Status.self]
    )
}

extension ServerCommand {
    struct Start: ContextCommand {
        static let configuration = CommandConfiguration(abstract: "Start the SMTP server, opening Dev Mail if needed.")

        func run(with context: CommandContext) throws {
            guard case .status(let status) = try context.connection.sendExpectingSuccess(.startServer) else {
                throw CLIError.unexpectedResponse
            }
            if status.state == .failed {
                throw CLIError("The SMTP server couldn't start: \(status.failureReason ?? "unknown error")")
            }
            guard status.state == .listening else {
                throw CLIError("The SMTP server didn't start. Check Dev Mail for details.")
            }
            context.print("Listening on \(AppFormatting.address(host: status.host, port: status.port)).")
        }
    }

    struct Stop: ContextCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the SMTP server. Dev Mail keeps running.")

        func run(with context: CommandContext) throws {
            guard case .status = try context.connection.sendExpectingSuccess(.stopServer, launchIfNeeded: false) else {
                throw CLIError.unexpectedResponse
            }
            context.print("Stopped.")
        }
    }

    struct Status: ContextCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show whether the SMTP server is running, where, and how many messages there are."
        )

        @Flag(help: "Print the status as JSON.")
        var json = false

        func run(with context: CommandContext) throws {
            let response: ControlResponse
            do {
                response = try context.connection.sendExpectingSuccess(.serverStatus, launchIfNeeded: false)
            } catch ControlClientError.notRunning {
                // Not an error: the question was answered.
                context.print(json ? try JSONOutput.string(StatusJSON(isAppRunning: false)) : "Dev Mail isn't running.")
                return
            }
            guard case .status(let status) = response else { throw CLIError.unexpectedResponse }

            if json {
                context.print(try JSONOutput.string(StatusJSON(isAppRunning: true, server: status)))
            } else {
                context.print(AppFormatting(style: context.style).status(status))
            }
        }
    }
}

/// The `--json` form of `server status`, which also covers the app not running.
private struct StatusJSON: Encodable {
    var isAppRunning: Bool
    var server: ControlServerStatus?
}
