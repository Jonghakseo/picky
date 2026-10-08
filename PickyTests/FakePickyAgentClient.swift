//
//  FakePickyAgentClient.swift
//  PickyTests
//
//  Shared in-memory PickyAgentClient fake, split out of PickySessionViewModelTests.swift.
//

import Foundation
@testable import Picky

final class FakePickyAgentClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    // `submitted` / `sentCommands` are mutated from `submit`/`send` (non-isolated
    // `async` protocol methods run on the cooperative pool) and read from the
    // tests' MainActor `wait { … }` / `#expect`. Without serializing, that's a
    // data race on Array<…> storage — reproducible as the
    // `slashCommandResourcesReloadedBumpsEpochAndReRequestsOnlyPreviouslyRequestedSession`
    // flake under heavy parallel xcodebuild load, where the reader sees stale
    // count/last and the next `#expect(count == 2)` fails. Hopping the append
    // onto MainActor.run gives both sides a single serialization point so the
    // observable buffer is always consistent with what the production code has
    // sent so far.
    @MainActor private(set) var submitted: [PickyAgentSubmission] = []
    @MainActor private(set) var sentCommands: [PickyCommandEnvelope] = []
    @MainActor var shouldThrowOnSend = false
    @MainActor var sendAwaitingErrorResult: PickyErrorEvent?
    @MainActor private(set) var acknowledgementRequirements: [Bool] = []
    @MainActor private(set) var acknowledgementTimeouts: [TimeInterval] = []
    @MainActor private(set) var renameRequests: [FakePickyRenameRequest] = []
    @MainActor var renameResult: PickyAgentSession?
    @MainActor var renameError: Error?
    var beforeSend: ((PickyCommandEnvelope) async -> Void)?

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        await MainActor.run { submitted.append(submission) }
        return PickyAgentSubmissionReceipt(sessionID: "session-1", message: "sent")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        if await MainActor.run(body: { shouldThrowOnSend }) {
            throw FakePickyAgentClientError.sendFailed
        }
        if let beforeSend {
            await beforeSend(command)
        }
        await MainActor.run { sentCommands.append(command) }
    }
    func sendAwaitingError(
        _ command: PickyCommandEnvelope,
        timeout: TimeInterval,
        requireAcknowledgement: Bool
    ) async throws -> PickyErrorEvent? {
        try await send(command)
        return await MainActor.run {
            acknowledgementRequirements.append(requireAcknowledgement)
            acknowledgementTimeouts.append(timeout)
            return sendAwaitingErrorResult
        }
    }
    func disconnect() { continuation.yield(.disconnected) }
    func emit(_ event: PickyClientEvent) { continuation.yield(event) }
}

/// The production client is the router, which owns rename routing. Tests that
/// exercise app-initiated renames record the request here instead.
extension FakePickyAgentClient: PickyPickleTitleRenaming {
    @MainActor
    func renamePickleTitle(sessionId: String, title: String, callerContext: PickyCliCallerContext?) async throws -> PickyAgentSession? {
        renameRequests.append(FakePickyRenameRequest(sessionId: sessionId, title: title, callerContext: callerContext))
        if let renameError { throw renameError }
        return renameResult
    }
}

struct FakePickyRenameRequest: Equatable {
    let sessionId: String
    let title: String
    let callerContext: PickyCliCallerContext?
}

private enum FakePickyAgentClientError: Error {
    case sendFailed
}
