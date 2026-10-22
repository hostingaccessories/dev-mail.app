import Combine
import Foundation
import Sparkle

/// Checks for and installs app updates with Sparkle, using the appcast at `SUFeedURL` in Info.plist.
@Observable
final class AppUpdater {
    /// False while a check is already running, or when the updater was never started.
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: AnyCancellable?

    /// - Parameter startingUpdater: Pass false to keep Sparkle idle, as in tests or builds without a signing key.
    init(startingUpdater: Bool) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Sparkle refuses updates without an EdDSA public key, so a build without one shouldn't start the updater.
    static func hasPublicEDKey(_ infoDictionary: [String: Any]?) -> Bool {
        let key = infoDictionary?["SUPublicEDKey"] as? String ?? ""
        return !key.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
