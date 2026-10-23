import Foundation

/// The Dev Mail app this tool belongs to. Installed, the tool is `Dev Mail.app/Contents/MacOS/dev-mail`, usually run
/// through a symlink such as Homebrew's.
enum AppBundle {
    static let bundleIdentifier = "com.hostingaccessories.DevMail"

    /// The `.app` containing this executable, after resolving symlinks, or `nil` when run from elsewhere (for
    /// example a development build of the tool on its own).
    static var enclosingApp: URL? {
        guard let executable = executableURL else { return nil }
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app"
        else { return nil }
        return app
    }

    /// The enclosing app's version, shown by `dev-mail --version`.
    static var version: String {
        guard let app = enclosingApp,
            let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
            let version = info["CFBundleShortVersionString"] as? String
        else { return "unknown" }
        return version
    }

    /// Opens the enclosing app, or the installed one if there's none, in the background and without a window, the
    /// way it opens at login.
    static func launchInBackground() throws {
        let target = enclosingApp.map { ["-a", $0.path(percentEncoded: false)] } ?? ["-b", bundleIdentifier]
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-g", "-j"] + target
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CLIError("Couldn't open Dev Mail: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError("Couldn't open Dev Mail. Is it installed?")
        }
    }

    /// This executable's path with symlinks resolved.
    private static var executableURL: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
    }
}
