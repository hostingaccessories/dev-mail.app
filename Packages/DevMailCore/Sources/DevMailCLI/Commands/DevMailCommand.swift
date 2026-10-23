import ArgumentParser

/// `dev-mail`: controls the Dev Mail app from the terminal.
public struct DevMailCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "dev-mail",
        abstract: "Read and manage the mail Dev Mail catches, and control its SMTP server.",
        discussion: """
            Commands talk to the running Dev Mail app, opening it in the background if needed. \
            `server status` and `server stop` never open it.
            """,
        version: AppBundle.version,
        subcommands: [MailCommand.self, ServerCommand.self, ConfigureCommand.self]
    )

    public init() {}
}
