import ArgumentParser
import DevMailCore
import Foundation

extension MailCommand {
    struct Send: ContextCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a message to Dev Mail over SMTP.",
            discussion: """
                The body is read from standard input when it isn't a terminal and no --body, --html or --eml is \
                given:

                  echo "It works" | dev-mail mail send --to you@example.test --subject Test

                With --eml, a complete message is sent unchanged. Its envelope comes from --from, --to, --cc and \
                --bcc, or else from its From, To, Cc and Bcc headers.

                Prints the new message's ID.
                """
        )

        static let defaultSender = "dev-mail@localhost"

        @Option(help: "The sender. (default: \(Send.defaultSender))")
        var from: String?

        @Option(help: "A recipient, such as 'Jane <jane@example.test>'. Repeat, or separate with commas, for more.")
        // swiftlint:disable:next identifier_name
        var to: [String] = []

        @Option(help: "A Cc recipient.")
        // swiftlint:disable:next identifier_name
        var cc: [String] = []

        @Option(help: "A Bcc recipient: in the envelope, not the headers.")
        var bcc: [String] = []

        @Option(name: .shortAndLong, help: "The subject.")
        var subject: String?

        @Option(help: "The plain-text body.")
        var body: String?

        @Option(help: ArgumentHelp("An HTML body, from a file or '-' for standard input.", valueName: "file"))
        var html: String?

        @Option(help: ArgumentHelp("A file to attach. Repeat for more.", valueName: "file"))
        var attach: [String] = []

        @Option(
            name: [.customShort("H"), .long],
            help: "An extra header, such as 'X-Campaign: launch'. Repeat for more."
        )
        var header: [String] = []

        @Option(help: ArgumentHelp("A complete message to send as is, from a file or '-'.", valueName: "file"))
        var eml: String?

        @Option(help: "The SMTP host. (default: the address Dev Mail listens on)")
        var host: String?

        @Option(help: "The SMTP port. (default: the port Dev Mail listens on)")
        var port: UInt16?

        func validate() throws {
            if eml != nil {
                let composing = subject != nil || body != nil || html != nil || !attach.isEmpty || !header.isEmpty
                guard !composing else {
                    throw ValidationError(
                        "--eml sends a message as is; it can't be used with --subject, --body, "
                            + "--html, --attach or --header."
                    )
                }
            } else if to.isEmpty, cc.isEmpty, bcc.isEmpty {
                throw ValidationError("Add a recipient with --to, --cc or --bcc.")
            }
            if port == 0 {
                throw ValidationError("--port must be from 1 to 65535.")
            }
        }

        func run(with context: CommandContext) throws {
            let message =
                try eml.map { try rawMessage(from: $0, context: context) } ?? composedMessage(context: context)
            let client = try smtpClient(context: context)

            let delivery: SMTPClient.Delivery
            do {
                delivery = try client.send(message.data, from: message.sender, to: message.recipients)
            } catch {
                throw CLIError(error.localizedDescription)
            }
            context.print(delivery.queuedID.map(MessageIDMatcher.shortID) ?? "Sent.")
        }

        // MARK: - Message

        private func composedMessage(context: CommandContext) throws -> PreparedMessage {
            let from = try Self.addresses(from ?? Self.defaultSender, option: "--from")
            guard from.count == 1, let sender = from.first else { throw CLIError("--from takes one address.") }

            var textBody = body
            var htmlBody: String?
            if let html {
                htmlBody = try Self.text(
                    try read(html, context: context),
                    source: html == "-" ? "Standard input" : html
                )
            } else if textBody == nil, let readInput = context.readInput {
                textBody = try Self.text(readInput(), source: "Standard input")
            }

            let message = OutgoingMessage(
                from: sender,
                to: try to.flatMap { try Self.addresses($0, option: "--to") },
                cc: try cc.flatMap { try Self.addresses($0, option: "--cc") },
                bcc: try bcc.flatMap { try Self.addresses($0, option: "--bcc") },
                subject: subject,
                textBody: textBody,
                htmlBody: htmlBody,
                attachments: try attach.map(Self.attachment),
                extraHeaders: try header.map(Self.header)
            )
            do {
                return PreparedMessage(
                    data: try MessageComposer.compose(message),
                    sender: sender.address,
                    recipients: message.envelopeRecipients
                )
            } catch {
                throw CLIError(error.localizedDescription)
            }
        }

        /// The message as given, with its envelope from the options or else its headers.
        private func rawMessage(from source: String, context: CommandContext) throws -> PreparedMessage {
            let data = try read(source, context: context)
            let parsed = MIMEParser.parse(data)

            let sender =
                try from.map { try Self.addresses($0, option: "--from").first?.address } ?? parsed.from.first?.address
            var recipients = try (to + cc + bcc).flatMap { try Self.addresses($0, option: "recipient") }.map(\.address)
            if recipients.isEmpty {
                recipients = (parsed.to + parsed.cc + parsed.bcc).map(\.address)
            }
            guard !recipients.isEmpty else {
                throw CLIError("The message has no To, Cc or Bcc header. Add a recipient with --to, --cc or --bcc.")
            }
            return PreparedMessage(data: data, sender: sender, recipients: recipients)
        }

        private func read(_ source: String, context: CommandContext) throws -> Data {
            if source == "-" {
                guard let readInput = context.readInput else {
                    throw CLIError("Standard input is a terminal; pipe the content in or pass a file.")
                }
                return readInput()
            }
            do {
                return try Data(contentsOf: URL(filePath: source))
            } catch {
                throw CLIError("Couldn't read \(source): \(error.localizedDescription)")
            }
        }

        private static func text(_ data: Data, source: String) throws -> String {
            guard let text = String(bytes: data, encoding: .utf8) else { throw CLIError("\(source) isn't UTF-8 text.") }
            return text
        }

        private static func addresses(_ text: String, option: String) throws -> [EmailAddress] {
            let addresses = EmailAddress.parseList(text)
            guard !addresses.isEmpty else { throw CLIError("\(option): \"\(text)\" is not an email address.") }
            return addresses
        }

        private static func attachment(_ path: String) throws -> OutgoingAttachment {
            do {
                return try OutgoingAttachment(contentsOf: URL(filePath: path))
            } catch {
                throw CLIError("Couldn't read \(path): \(error.localizedDescription)")
            }
        }

        private static func header(_ text: String) throws -> MessageHeader {
            guard let colon = text.firstIndex(of: ":") else {
                throw CLIError("--header: \"\(text)\" should look like 'Name: value'.")
            }
            return MessageHeader(
                name: text[..<colon].trimmingCharacters(in: .whitespaces),
                value: text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            )
        }

        // MARK: - Server

        /// The given host and port, filling in whichever is missing from where Dev Mail listens. Opens Dev Mail if
        /// it's needed and not running.
        private func smtpClient(context: CommandContext) throws -> SMTPClient {
            if let host, let port {
                return SMTPClient(host: host, port: port)
            }
            guard case .status(let status) = try context.connection.sendExpectingSuccess(.serverStatus) else {
                throw CLIError.unexpectedResponse
            }
            guard status.state == .listening else {
                throw CLIError("Dev Mail's SMTP server isn't running. Start it with `dev-mail server start`.")
            }
            return SMTPClient(host: host ?? Self.connectableHost(status.host), port: port ?? status.port)
        }

        /// A server listening on every address is reached over loopback.
        static func connectableHost(_ host: String) -> String {
            switch host {
            case "0.0.0.0": "127.0.0.1"
            case "::", "::0": "::1"
            default: host
            }
        }
    }
}

/// The bytes `mail send` sends and their envelope.
private struct PreparedMessage {
    var data: Data
    var sender: String?
    var recipients: [String]
}
