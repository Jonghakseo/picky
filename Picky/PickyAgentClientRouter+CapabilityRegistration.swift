//
//  PickyAgentClientRouter+CapabilityRegistration.swift
//  Picky
//
//  Every connection must advertise its capability set before any other command
//  goes out on it. A legacy command reaching agentd first locks that socket's
//  projection dialect to v1, which permanently rejects the app's
//  `sessionProjectionV2` registration.
//

import Foundation

extension PickyAgentClientRouter {
    func sendAfterCapabilityRegistration(
        _ command: PickyCommandEnvelope,
        on client: PickyAgentClient
    ) async throws {
        if let ownerKey = clientEventKeys[ObjectIdentifier(client)] {
            try await waitForCapabilityRegistration(ownerKey: ownerKey)
        }
        try await client.send(command)
    }

    /// Gating a command on registration must never outlast the daemon itself.
    /// Without this bound a daemon that never connects would convert a fast
    /// `send` failure into an indefinite hang, which is the same stall class
    /// this gate exists to prevent.
    func waitForCapabilityRegistration(ownerKey: String) async throws {
        guard capabilityRegistrationStates[ownerKey] != .registered else { return }
        let waiterID = UUID()
        let timeoutNanoseconds = capabilityRegistrationTimeoutNanoseconds
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.cancelCapabilityRegistrationWaiter(ownerKey: ownerKey, waiterID: waiterID)
        }
        defer { timeout.cancel() }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if self.capabilityRegistrationStates[ownerKey] == .registered {
                    continuation.resume()
                    return
                }
                self.capabilityRegistrationWaiters[ownerKey, default: [:]][waiterID] = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelCapabilityRegistrationWaiter(ownerKey: ownerKey, waiterID: waiterID)
            }
        })
        guard capabilityRegistrationStates[ownerKey] == .registered else {
            throw PickyAgentClientRouterError.capabilityRegistrationUnavailable(ownerKey: ownerKey)
        }
    }

    /// The registration command ID is deliberately retained after a successful
    /// send. The daemon can still reject it (a legacy command may already have
    /// locked the socket dialect), and that rejection arrives later as a
    /// correlated `error` event.
    ///
    /// The retry counter is deliberately *not* reset here. A rejection always
    /// follows a successful send, so resetting on send would let a permanently
    /// rejecting daemon loop through reconnects forever.
    func completeCapabilityRegistration(ownerKey: String) {
        capabilityRegistrationStates[ownerKey] = .registered
        let waiters = capabilityRegistrationWaiters.removeValue(forKey: ownerKey).map { Array($0.values) } ?? []
        for waiter in waiters { waiter.resume() }
    }

    func cancelCapabilityRegistrationWaiter(ownerKey: String, waiterID: UUID) {
        let waiter = capabilityRegistrationWaiters[ownerKey]?.removeValue(forKey: waiterID)
        if capabilityRegistrationWaiters[ownerKey]?.isEmpty == true {
            capabilityRegistrationWaiters[ownerKey] = nil
        }
        waiter?.resume()
    }

    func discardCapabilityRegistration(ownerKey: String) {
        capabilityRegistrationStates[ownerKey] = nil
        capabilityRegistrationCommandIDs[ownerKey] = nil
        capabilityRegistrationRetryCounts[ownerKey] = nil
        let waiters = capabilityRegistrationWaiters.removeValue(forKey: ownerKey).map { Array($0.values) } ?? []
        for waiter in waiters { waiter.resume() }
    }

    /// Reconnecting is the only way to clear a wrongly locked socket dialect,
    /// but an unconditional retry spins disconnect/connect as fast as the
    /// daemon can reject. Back off and give up loudly instead.
    func retryCapabilityRegistration(on client: PickyAgentClient, ownerKey: String, reason: String) {
        capabilityRegistrationStates[ownerKey] = .awaitingConnection
        capabilityRegistrationCommandIDs[ownerKey] = nil
        let attempt = (capabilityRegistrationRetryCounts[ownerKey] ?? 0) + 1
        capabilityRegistrationRetryCounts[ownerKey] = attempt
        guard attempt <= Self.maximumCapabilityRegistrationRetries else {
            pickyAgentRouterLog("capability registration retries exhausted owner=\(ownerKey) reason=\(reason)")
            broadcast(.recoverableError("Picky agent could not register capabilities (\(reason)). Restart Picky to reconnect."))
            return
        }
        pickyAgentRouterLog("capability registration retry owner=\(ownerKey) attempt=\(attempt) reason=\(reason)")
        let backoff = capabilityRegistrationRetryBackoffNanoseconds << (attempt - 1)
        client.disconnect()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: backoff)
            await client.connect()
        }
    }

    func handleCapabilityRegistrationFailure(
        _ error: PickyErrorEvent,
        on client: PickyAgentClient,
        ownerKey: String
    ) {
        guard let commandID = error.commandId,
              capabilityRegistrationCommandIDs[ownerKey] == commandID
        else { return }

        pickyAgentRouterLog("capability registration rejected owner=\(ownerKey) error=\(error.message)")
        retryCapabilityRegistration(on: client, ownerKey: ownerKey, reason: error.message)
    }
}
