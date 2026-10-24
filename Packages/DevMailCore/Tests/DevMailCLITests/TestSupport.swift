import DevMailCore
import Foundation
import Synchronization
import Testing

@testable import DevMailCLI

/// Runs `body` with a stub app answering on a control socket. When not `running`, the socket only starts once the
/// command launches the app, and not at all unless `startsOnLaunch`.
func withApp(
    answering response: ControlResponse,
    running: Bool = true,
    startsOnLaunch: Bool = true,
    _ body: (StubApp) async throws -> Void
) async throws {
    try await withApp({ _ in response }, running: running, startsOnLaunch: startsOnLaunch, body)
}

func withApp(
    _ handler: @escaping ControlServer.Handler,
    running: Bool = true,
    startsOnLaunch: Bool = true,
    _ body: (StubApp) async throws -> Void
) async throws {
    let directory = URL(filePath: "/tmp/dmcli-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    let server = ControlServer(socketURL: directory.appending(path: "control.sock"), handler: handler)
    let app = StubApp(server: server, socketURL: server.socketURL, startsOnLaunch: startsOnLaunch)
    if running {
        try await server.start()
    }
    do {
        try await body(app)
    } catch {
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
    await server.stop()
    try? FileManager.default.removeItem(at: directory)
}

/// Stands in for the app: counts launches, starts the control server on the first one, and answers prompts.
final class StubApp: Sendable {
    private struct State {
        var launchCount = 0
        var questions: [String] = []
    }

    let server: ControlServer
    let socketURL: URL
    let startsOnLaunch: Bool
    private let state = Mutex(State())

    init(server: ControlServer, socketURL: URL, startsOnLaunch: Bool) {
        self.server = server
        self.socketURL = socketURL
        self.startsOnLaunch = startsOnLaunch
    }

    var launchCount: Int { state.withLock(\.launchCount) }
    var questions: [String] { state.withLock(\.questions) }

    /// Runs a command line and returns what it printed. `answer` is the reply to any prompt and `input` is standard
    /// input; `nil` means standard input is a terminal or nobody is there to answer. Runs on a plain thread because the
    /// client blocks while the server answers.
    func run(_ arguments: [String], answer: Bool? = nil, input: Data? = nil) async throws -> String {
        let command = try DevMailCommand.parseAsRoot(arguments)
        guard let command = command as? any ContextCommand else { throw CLIError("Not a runnable command") }
        let output = OutputBuffer()
        var context = makeContext(output: output, answer: answer)
        context.readInput = input.map { input in { input } }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            nonisolated(unsafe) let command = command
            nonisolated(unsafe) let context = context
            Thread.detachNewThread {
                continuation.resume(with: Result { try command.run(with: context) })
            }
        }
        return output.text
    }

    private func makeContext(output: OutputBuffer, answer: Bool?) -> CommandContext {
        let connection = AppConnection(
            client: ControlClient(socketURL: socketURL, timeout: .seconds(5)),
            launch: { [self] in
                state.withLock { $0.launchCount += 1 }
                guard startsOnLaunch else { return }
                // The real launch is asynchronous too: the command waits for the socket to appear.
                Task { try? await self.server.start() }
            },
            launchTimeout: .milliseconds(500)
        )
        return CommandContext(
            connection: connection,
            style: .plain,
            now: { Fixtures.now },
            write: output.append,
            confirm: answer.map { answer in
                { [self] question in
                    state.withLock { $0.questions.append(question) }
                    return answer
                }
            }
        )
    }
}

/// Collects what a command writes to standard output.
final class OutputBuffer: Sendable {
    private let data = Mutex(Data())

    var text: String { data.withLock { String(bytes: $0, encoding: .utf8) ?? "" } }

    func append(_ bytes: Data) {
        data.withLock { $0.append(bytes) }
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
