import ArgumentParser
import Darwin
import Foundation

/// An error shown to the user as `Error: <message>`, exiting with status 1.
struct CLIError: Error, CustomStringConvertible, Equatable {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    static let unexpectedResponse = CLIError("Dev Mail sent an unexpected response.")
}

/// Everything a command touches outside its own arguments, so tests can run commands without a terminal or the app.
struct CommandContext {
    var connection: AppConnection
    var style: TerminalStyle
    var now: () -> Date = { Date() }

    /// Writes to standard output.
    var write: (Data) -> Void

    /// Asks a yes/no question, or is `nil` when there's nobody to ask (standard input isn't a terminal).
    var confirm: ((String) -> Bool)?

    func print(_ text: String) {
        write(Data((text + "\n").utf8))
    }

    static var live: CommandContext {
        let confirm: ((String) -> Bool)? = isatty(STDIN_FILENO) == 1 ? { askOnTerminal($0) } : nil
        return CommandContext(
            connection: .live,
            style: .forStandardOutput(),
            write: { FileHandle.standardOutput.write($0) },
            confirm: confirm
        )
    }

    /// Prompts on standard error, so the question isn't mixed into output that's piped elsewhere.
    private static func askOnTerminal(_ question: String) -> Bool {
        FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}

/// A command that talks to the app. Its work is in `run(with:)`; `run()` supplies the real terminal and app.
protocol ContextCommand: ParsableCommand {
    func run(with context: CommandContext) throws
}

extension ContextCommand {
    func run() throws {
        try run(with: .live)
    }
}

/// Bold and dim text, used only when writing to a terminal that wants it.
struct TerminalStyle: Sendable {
    var isEnabled: Bool

    static let plain = TerminalStyle(isEnabled: false)

    /// Styled when standard output is a terminal, unless `NO_COLOR` is set (https://no-color.org) or `TERM` is `dumb`.
    static func forStandardOutput(environment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalStyle
    {
        let wantsPlain = !(environment["NO_COLOR"] ?? "").isEmpty || environment["TERM"] == "dumb"
        return TerminalStyle(isEnabled: isatty(STDOUT_FILENO) == 1 && !wantsPlain)
    }

    func bold(_ text: String) -> String {
        isEnabled ? "\u{1B}[1m\(text)\u{1B}[22m" : text
    }

    func dim(_ text: String) -> String {
        isEnabled ? "\u{1B}[2m\(text)\u{1B}[22m" : text
    }
}

/// Pretty-printed JSON with stable key order and ISO 8601 dates, for `--json` output.
enum JSONOutput {
    static func string(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // JSONEncoder always produces UTF-8.
        return String(bytes: try encoder.encode(value), encoding: .utf8) ?? ""
    }
}
