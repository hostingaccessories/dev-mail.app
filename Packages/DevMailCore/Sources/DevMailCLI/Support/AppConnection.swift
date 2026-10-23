import DevMailCore
import Foundation

/// Sends requests to the app, opening it in the background first when a command needs it running.
struct AppConnection {
    var client: ControlClient

    /// Opens the app without bringing it to the front.
    var launch: () throws -> Void

    /// How long to wait for a launched app to start listening.
    var launchTimeout: Duration = .seconds(15)

    static var live: AppConnection {
        AppConnection(client: ControlClient(), launch: AppBundle.launchInBackground)
    }

    /// Sends `request`, opening the app first if it isn't running and `launchIfNeeded` is set.
    ///
    /// - Throws: `ControlClientError.notRunning` if the app isn't running and isn't to be opened, or a `CLIError` if it
    ///   doesn't start in time.
    func send(_ request: ControlRequest, launchIfNeeded: Bool = true) throws -> ControlResponse {
        do {
            return try client.send(request)
        } catch .notRunning where launchIfNeeded {
            try launchAndWait()
            return try client.send(request)
        }
    }

    /// Sends `request` and turns a `failure` response into an error.
    func sendExpectingSuccess(_ request: ControlRequest, launchIfNeeded: Bool = true) throws -> ControlResponse {
        let response = try send(request, launchIfNeeded: launchIfNeeded)
        if case .failure(let reason) = response {
            throw CLIError(reason)
        }
        return response
    }

    /// Opens the app and waits for its control socket, which it opens once the messages are loaded.
    private func launchAndWait() throws {
        try launch()
        let deadline = ContinuousClock.now + launchTimeout
        var delay = Duration.milliseconds(50)
        while !client.isAppRunning {
            guard ContinuousClock.now < deadline else {
                throw CLIError("Dev Mail didn't start in time.")
            }
            Thread.sleep(forTimeInterval: delay / .seconds(1))
            delay = min(delay * 2, .milliseconds(500))
        }
    }
}
