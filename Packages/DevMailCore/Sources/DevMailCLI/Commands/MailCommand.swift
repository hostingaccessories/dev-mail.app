import ArgumentParser
import DevMailCore
import Foundation

struct MailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "List, show and delete caught messages.",
        subcommands: [List.self, Show.self, Delete.self]
    )
}

extension MailCommand {
    struct List: ContextCommand {
        static let configuration = CommandConfiguration(
            abstract: "List messages, newest first.",
            discussion: "Unread messages are shown in bold. Pass an ID, or its first few characters, to `mail show`."
        )

        @Option(name: .shortAndLong, help: "Only messages whose subject, sender or recipients contain this text.")
        var search: String?

        @Option(name: [.customShort("n"), .long], help: "Show at most this many messages.")
        var limit: Int?

        @Flag(help: "Only unread messages.")
        var unread = false

        @Flag(help: "Print the messages as JSON.")
        var json = false

        func validate() throws {
            if let limit, limit < 1 {
                throw ValidationError("--limit must be at least 1.")
            }
        }

        func run(with context: CommandContext) throws {
            let request = ControlRequest.listMessages(query: search, limit: limit, unreadOnly: unread)
            guard case .messages(let summaries) = try context.connection.sendExpectingSuccess(request) else {
                throw CLIError.unexpectedResponse
            }
            if json {
                context.print(try JSONOutput.string(summaries))
            } else {
                context.print(MessageFormatting(style: context.style, now: context.now()).table(summaries))
            }
        }
    }

    struct Show: ContextCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a message.",
            discussion: "By default, shows the main headers, the plain-text body (or the HTML as text) and attachments."
        )

        @Argument(help: "The message's ID, or enough of its first characters to be unique.")
        var id: String

        @Flag(help: "Print the original message source (.eml) unchanged.")
        var raw = false

        @Flag(help: "Print the HTML body.")
        var html = false

        @Flag(help: "Print every header.")
        var headers = false

        @Flag(help: "Print the message as JSON.")
        var json = false

        func validate() throws {
            guard [raw, html, headers, json].count(where: \.self) <= 1 else {
                throw ValidationError("Use only one of --raw, --html, --headers and --json.")
            }
        }

        func run(with context: CommandContext) throws {
            let response = try context.connection.sendExpectingSuccess(.showMessage(id: id))
            guard case .message(let summary, let data) = response else { throw CLIError.unexpectedResponse }
            if raw {
                context.write(data)
                return
            }

            let parsed = MIMEParser.parse(data)
            let formatting = MessageFormatting(style: context.style, now: context.now())
            if html {
                guard let body = parsed.htmlBody else { throw CLIError("The message has no HTML body.") }
                context.print(body)
            } else if headers {
                context.print(formatting.headers(parsed))
            } else if json {
                context.print(try JSONOutput.string(MessageJSON(summary: summary, parsed: parsed)))
            } else {
                context.print(formatting.message(summary, parsed: parsed))
            }
        }
    }

    struct Delete: ContextCommand {
        static let configuration = CommandConfiguration(abstract: "Delete messages by ID, or all of them.")

        @Argument(help: "IDs of the messages to delete, or enough of their first characters to be unique.")
        var ids: [String] = []

        @Flag(help: "Delete every message.")
        var all = false

        @Flag(name: .shortAndLong, help: "Don't ask before deleting every message.")
        var yes = false

        func validate() throws {
            if all, !ids.isEmpty {
                throw ValidationError("Pass either message IDs or --all, not both.")
            }
            if !all, ids.isEmpty {
                throw ValidationError("Pass message IDs or --all.")
            }
        }

        func run(with context: CommandContext) throws {
            if all, !yes {
                guard let confirm = context.confirm else {
                    throw CLIError("Pass --yes to delete every message without being asked.")
                }
                guard confirm("Delete all messages? This can't be undone.") else { return }
            }

            let request: ControlRequest = all ? .deleteAllMessages : .deleteMessages(ids: ids)
            guard case .deleted(let count) = try context.connection.sendExpectingSuccess(request) else {
                throw CLIError.unexpectedResponse
            }
            context.print(count == 1 ? "Deleted 1 message." : "Deleted \(count) messages.")
        }
    }
}
