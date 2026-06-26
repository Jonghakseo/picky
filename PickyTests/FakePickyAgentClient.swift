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
        if let beforeSend {
            await beforeSend(command)
        }
        await MainActor.run { sentCommands.append(command) }
    }
    func disconnect() { continuation.yield(.disconnected) }
    func emit(_ event: PickyClientEvent) { continuation.yield(event) }
}
