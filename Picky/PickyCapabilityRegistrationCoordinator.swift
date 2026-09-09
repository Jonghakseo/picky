//
//  PickyCapabilityRegistrationCoordinator.swift
//  Picky
//
//  Owns the connection capability-registration lifecycle independently from
//  command routing. Every tracked connection must register before legacy
//  commands can be sent, and a rejected registration retries only within a
//  bounded budget.
//

import Foundation

@MainActor
final class PickyCapabilityRegistrationCoordinator {
    private enum State: Equatable {
        case awaitingConnection
        case registering
        case registered
    }

    private let timeoutNanoseconds: UInt64
    private let retryBackoffNanoseconds: UInt64
    private let maximumRetries: Int
    private var states: [String: State] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var commandIDs: [String: String] = [:]
    private var retryCounts: [String: Int] = [:]

    init(
        timeoutNanoseconds: UInt64,
        retryBackoffNanoseconds: UInt64,
        maximumRetries: Int = 3
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.retryBackoffNanoseconds = retryBackoffNanoseconds
        self.maximumRetries = maximumRetries
    }

    /// A connection that never registers must fail queued commands within
    /// the configured deadline rather than leave them waiting indefinitely.
    func waitUntilRegistered(ownerKey: String) async throws {
        guard states[ownerKey] != .registered else { return }
        let waiterID = UUID()
        let timeoutNanoseconds = timeoutNanoseconds
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.cancelWaiter(ownerKey: ownerKey, waiterID: waiterID)
        }
        defer { timeout.cancel() }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if self.states[ownerKey] == .registered {
                    continuation.resume()
                    return
                }
                self.waiters[ownerKey, default: [:]][waiterID] = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelWaiter(ownerKey: ownerKey, waiterID: waiterID)
            }
        })
        guard states[ownerKey] == .registered else {
            throw PickyAgentClientRouterError.capabilityRegistrationUnavailable(ownerKey: ownerKey)
        }
    }

    func beginTrackingConnection(ownerKey: String) {
        states[ownerKey] = .awaitingConnection
    }

    func beginRegistration(ownerKey: String, commandID: String) {
        states[ownerKey] = .registering
        commandIDs[ownerKey] = commandID
    }

    /// Completion means the registration frame was sent, not accepted by the
    /// daemon. Keep its command ID for a later correlated rejection, and keep
    /// the retry count so repeated send/reject cycles cannot retry forever.
    func completeRegistration(ownerKey: String) {
        states[ownerKey] = .registered
        resumeWaiters(ownerKey: ownerKey)
    }

    func registrationSendFailed(ownerKey: String) {
        states[ownerKey] = .awaitingConnection
        commandIDs[ownerKey] = nil
    }

    func connectionDidDisconnect(ownerKey: String) {
        states[ownerKey] = .awaitingConnection
        commandIDs[ownerKey] = nil
    }

    func discard(ownerKey: String) {
        states[ownerKey] = nil
        commandIDs[ownerKey] = nil
        retryCounts[ownerKey] = nil
        resumeWaiters(ownerKey: ownerKey)
    }

    /// Returns a user-visible error only after the bounded reconnect budget is
    /// exhausted. The router owns delivery of that error to its event stream.
    func handleRegistrationFailure(
        _ error: PickyErrorEvent,
        on client: PickyAgentClient,
        ownerKey: String
    ) -> String? {
        guard let commandID = error.commandId, commandIDs[ownerKey] == commandID else { return nil }

        pickyAgentRouterLog("capability registration rejected owner=\(ownerKey) error=\(error.message)")
        states[ownerKey] = .awaitingConnection
        commandIDs[ownerKey] = nil
        let attempt = (retryCounts[ownerKey] ?? 0) + 1
        retryCounts[ownerKey] = attempt
        guard attempt <= maximumRetries else {
            pickyAgentRouterLog(
                "capability registration retries exhausted owner=\(ownerKey) reason=\(error.message)"
            )
            return "Picky agent could not register capabilities (\(error.message)). Restart Picky to reconnect."
        }

        pickyAgentRouterLog(
            "capability registration retry owner=\(ownerKey) attempt=\(attempt) reason=\(error.message)"
        )
        let backoff = retryBackoffNanoseconds << (attempt - 1)
        client.disconnect()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: backoff)
            await client.connect()
        }
        return nil
    }

    private func cancelWaiter(ownerKey: String, waiterID: UUID) {
        let waiter = waiters[ownerKey]?.removeValue(forKey: waiterID)
        if waiters[ownerKey]?.isEmpty == true {
            waiters[ownerKey] = nil
        }
        waiter?.resume()
    }

    private func resumeWaiters(ownerKey: String) {
        let pendingWaiters = waiters.removeValue(forKey: ownerKey).map { Array($0.values) } ?? []
        for waiter in pendingWaiters { waiter.resume() }
    }
}
