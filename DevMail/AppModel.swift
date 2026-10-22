import DevMailCore
import Foundation
import Observation
import os

nonisolated private let logger = Logger(subsystem: "com.hostingaccessories.DevMail", category: "AppModel")

/// An error shown to the user in an alert.
struct AppError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    /// Whether the fix is likely a different host or port, so the alert offers to open Settings.
    let suggestsSettings: Bool
}

enum AppModelError: Error, LocalizedError {
    /// The message store could not be opened, so messages can't be read or saved.
    case storeUnavailable

    var errorDescription: String? {
        "The messages folder is unavailable."
    }
}

/// Owns the message store and the SMTP server and publishes their state to the UI.
///
/// Creating a model has no side effects; call `start()` to open the store and start the server.
@Observable @MainActor
final class AppModel {
    // MARK: - Messages

    /// Every stored message, newest first. Kept in sync with the store as messages arrive or change.
    private(set) var summaries: [MessageSummary] = []

    /// Filters `filteredSummaries` by subject, sender and recipients.
    var searchText = ""

    /// `summaries` matching `searchText`, newest first.
    var filteredSummaries: [MessageSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return summaries }
        return summaries.filter { $0.matches(query) }
    }

    var unreadCount: Int {
        summaries.count { !$0.isRead }
    }

    // MARK: - Server and settings

    private(set) var serverState = SMTPServer.State.stopped
    private(set) var serverConfiguration: SMTPServerConfiguration
    private(set) var retentionPolicy: RetentionPolicy

    /// The most recent error to show the user; set to `nil` to dismiss it.
    var lastError: AppError?

    // MARK: - Private state

    /// The messages folder.
    let directory: URL
    private var store: MessageStore?
    private var server: SMTPServer?
    private var hasStarted = false
    private var isShutDown = false
    private var changesTask: Task<Void, Never>?
    private var serverStateTask: Task<Void, Never>?

    /// The last queued server operation. Start, stop and restart await each other so overlapping calls (a double
    /// click, a restart during quit) never leave two servers running.
    private var serverOperation: Task<Void, Never>?

    init(
        directory: URL = MessageStore.defaultDirectory,
        configuration: SMTPServerConfiguration = SMTPServerConfiguration(),
        retentionPolicy: RetentionPolicy = RetentionPolicy()
    ) {
        self.directory = directory
        self.serverConfiguration = configuration
        self.retentionPolicy = retentionPolicy
    }

    // MARK: - Lifecycle

    /// Opens the store, loads the messages and starts the server. Does nothing after the first call.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        await openStore()
        if store != nil {
            await startServer()
        }
    }

    /// Stops the server and stops observing the store. Call before the app quits.
    func shutdown() async {
        isShutDown = true
        await serialized { await self.performStop() }
        changesTask?.cancel()
        changesTask = nil
    }

    // MARK: - Server control

    func startServer() async {
        await serialized { await self.performStart() }
    }

    func stopServer() async {
        await serialized { await self.performStop() }
    }

    /// Stops the server if it is running and starts it again with `configuration`.
    func restartServer(with configuration: SMTPServerConfiguration) async {
        await serialized {
            await self.performStop()
            self.serverConfiguration = configuration
            await self.performStart()
        }
    }

    func updateRetentionPolicy(_ policy: RetentionPolicy) async {
        retentionPolicy = policy
        await store?.updateRetentionPolicy(policy)
    }

    // MARK: - Message actions

    func parsedMessage(for id: UUID) async throws -> ParsedMessage {
        try await requireStore().parsedMessage(for: id)
    }

    /// Location of the message's `.eml` file, for "Open in Mail" or "Show in Finder".
    func fileURL(for id: UUID) async throws -> URL {
        try await requireStore().fileURL(for: id)
    }

    func markRead(_ id: UUID, isRead: Bool) async {
        await performStoreAction("Couldn't Update Message") { try await $0.setRead(isRead, for: id) }
    }

    func delete(ids: Set<UUID>) async {
        await performStoreAction("Couldn't Delete Messages") { try await $0.delete(ids: ids) }
    }

    func deleteAll() async {
        await performStoreAction("Couldn't Delete Messages") { try await $0.deleteAll() }
    }

    // MARK: - Store

    private func openStore() async {
        let store: MessageStore
        do {
            store = try await MessageStore(directory: directory, retentionPolicy: retentionPolicy)
        } catch {
            logger.error("Failed to open message store: \(error.localizedDescription, privacy: .public)")
            present(AppError(title: "Couldn't Open Messages", message: error.localizedDescription))
            return
        }
        self.store = store

        // Subscribe before loading so nothing is missed in between. Changes that are already reflected in the
        // snapshot are replayed harmlessly: each one sets a message's final value or removes it.
        let changes = await store.changes()
        summaries = await store.summaries()
        changesTask = Task { [weak self] in
            for await change in changes {
                self?.apply(change)
            }
        }
    }

    private func apply(_ change: MessageStoreChange) {
        switch change {
        case .added(let summary), .updated(let summary):
            summaries.removeAll { $0.id == summary.id }
            let index = summaries.firstIndex { MessageSummary.newestFirst(summary, $0) } ?? summaries.endIndex
            summaries.insert(summary, at: index)
        case .removed(let ids):
            summaries.removeAll { ids.contains($0.id) }
        }
    }

    private func requireStore() throws -> MessageStore {
        guard let store else { throw AppModelError.storeUnavailable }
        return store
    }

    private func performStoreAction(
        _ failureTitle: String,
        _ action: (MessageStore) async throws -> Void
    ) async {
        do {
            try await action(requireStore())
        } catch {
            logger.error("\(failureTitle, privacy: .public): \(error.localizedDescription, privacy: .public)")
            present(AppError(title: failureTitle, message: error.localizedDescription))
        }
    }

    // MARK: - Server

    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = serverOperation
        let task = Task {
            await previous?.value
            await operation()
        }
        serverOperation = task
        await task.value
    }

    private func performStart() async {
        guard !isShutDown else { return }
        if server != nil, case .listening = serverState { return }
        await discardServer()

        let store: MessageStore
        do {
            store = try requireStore()
        } catch {
            present(AppError(title: "Couldn't Start Server", message: error.localizedDescription))
            return
        }

        let server = SMTPServer(
            configuration: serverConfiguration,
            deliver: Self.deliveryHandler(store: store) { [weak self] reason in
                self?.present(AppError(title: "Couldn't Save Message", message: reason))
            }
        )
        self.server = server
        do {
            try await server.start()
        } catch {
            // A failed server holds no listener or connections; stopping it just settles its state.
            await server.stop()
            self.server = nil
            let serverError = error as? SMTPServerError ?? .listenerFailed(reason: error.localizedDescription)
            serverState = .failed(serverError)
            reportServerFailure(serverError)
            return
        }
        serverState = await server.state
        observeState(of: server)
    }

    private func performStop() async {
        await discardServer()
        serverState = .stopped
    }

    private func discardServer() async {
        serverStateTask?.cancel()
        serverStateTask = nil
        guard let server else { return }
        self.server = nil
        await server.stop()
    }

    /// Mirrors state changes after a successful start, such as the listener failing later on.
    private func observeState(of server: SMTPServer) {
        serverStateTask = Task { [weak self] in
            for await state in await server.stateUpdates() {
                guard let self, self.server === server else { return }
                if state != self.serverState, case .failed(let error) = state {
                    self.reportServerFailure(error)
                }
                self.serverState = state
            }
        }
    }

    private func reportServerFailure(_ error: SMTPServerError) {
        logger.error("SMTP server failed: \(error.localizedDescription, privacy: .public)")
        let suggestsSettings: Bool
        switch error {
        case .addressInUse, .permissionDenied: suggestsSettings = true
        case .listenerFailed: suggestsSettings = false
        }
        present(
            AppError(
                title: "Couldn't Start the SMTP Server",
                message: error.localizedDescription,
                suggestsSettings: suggestsSettings
            )
        )
    }

    private func present(_ error: AppError) {
        lastError = error
    }

    /// Saves each received message. A failed save is logged and shown to the user, but the client is still told the
    /// message was accepted: rejecting it would only make the sending app retry or crash, which doesn't help debug.
    nonisolated private static func deliveryHandler(
        store: MessageStore,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) -> SMTPServer.DeliveryHandler {
        { message in
            do {
                try await store.add(message)
            } catch {
                let reason = error.localizedDescription
                logger.error(
                    "Failed to save message \(message.id.uuidString, privacy: .public): \(reason, privacy: .public)"
                )
                // Not awaited, so the client's reply doesn't wait on the main thread.
                Task { @MainActor in onFailure(reason) }
            }
        }
    }
}

extension AppError {
    init(title: String, message: String) {
        self.init(title: title, message: message, suggestsSettings: false)
    }
}
