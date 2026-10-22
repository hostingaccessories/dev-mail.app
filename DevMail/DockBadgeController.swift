import AppKit
import Observation

/// Shows the unread count on the Dock icon. Owned by the app delegate so it keeps working with the window closed.
final class DockBadgeController {
    private let model: AppModel
    private var isStarted = false

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        update()
    }

    /// The Dock badge text, or `nil` to hide the badge.
    nonisolated static func badgeLabel(unreadCount: Int) -> String? {
        unreadCount > 0 ? String(unreadCount) : nil
    }

    private func update() {
        // `onChange` fires once, before the change is applied, so re-read and re-register on the next main-actor turn.
        let unreadCount = withObservationTracking {
            model.unreadCount
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
        let label = Self.badgeLabel(unreadCount: unreadCount)
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
        }
    }
}
