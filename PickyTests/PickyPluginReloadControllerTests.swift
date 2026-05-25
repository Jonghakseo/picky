//
//  PickyPluginReloadControllerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyPluginReloadControllerTests {

    @Test func notePluginsChangedFlagsBannerVisible() async throws {
        let client = LocalStubPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)

        #expect(controller.hasPendingChanges == false)
        controller.notePluginsChanged()
        #expect(controller.hasPendingChanges == true)
        #expect(controller.lastResult == nil)
        #expect(controller.lastError == nil)
    }

    @Test func reloadSendsReloadPluginsCommand() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()

        await controller.reload()

        #expect(client.sentCommands.contains(where: { $0.type == .reloadPlugins }))
        #expect(controller.isReloading == true) // cleared by pluginsReloaded event, not yet emitted
    }

    @Test func pluginsReloadedEventClearsPendingFlagAndStoresSummary() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()

        client.emit(makeReloadedEvent(picky: true, reloaded: 2, aborted: 1, deferred: 0))
        // Poll for the controller to apply the event. The events loop runs on a
        // separate MainActor-hopping Task, so a fixed sleep is racy under load.
        try await waitUntil(timeoutMs: 2_000) { controller.lastResult != nil }

        #expect(controller.hasPendingChanges == false)
        #expect(controller.isReloading == false)
        #expect(controller.lastResult?.pickyReloaded == true)
        #expect(controller.lastResult?.pickleReloadedCount == 2)
        #expect(controller.lastResult?.pickleAbortedCount == 1)
        #expect(controller.lastResult?.pickleDeferredCount == 0)
    }

    @Test func pluginsReloadedKeepsBannerWhenChangedDuringReload() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()
        controller.notePluginsChanged()

        client.emit(makeReloadedEvent(picky: true, reloaded: 1, aborted: 0, deferred: 0))
        try await waitUntil(timeoutMs: 2_000) { controller.lastResult != nil }

        #expect(controller.hasPendingChanges == true)
        #expect(controller.isReloading == false)
    }

    @Test func reloadStoresErrorWhenClientThrows() async throws {
        let client = ThrowingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()

        await controller.reload()

        #expect(controller.isReloading == false)
        #expect(controller.lastError != nil)
        // hasPendingChanges stays true so the user can retry.
        #expect(controller.hasPendingChanges == true)
    }

    @Test func concurrentReloadDoesNotEnqueueDuplicateCommands() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()

        // Kick two reloads back-to-back; the second should bail out because
        // isReloading is already true after the first.
        async let first: Void = controller.reload()
        async let second: Void = controller.reload()
        _ = await (first, second)

        #expect(client.sentCommands.filter { $0.type == .reloadPlugins }.count == 1)
    }

    @Test func reloadIsReleasedOnDisconnect() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()

        client.emit(.disconnected)
        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }

        #expect(controller.hasPendingChanges == true)
        #expect(controller.lastError == L10n.t("status.extensions.reload.error.disconnected"))
    }

    @Test func reloadIsReleasedOnRecoverableError() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()

        client.emit(.recoverableError("decode failed"))
        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }

        #expect(controller.hasPendingChanges == true)
        #expect(controller.lastError == "decode failed")
    }

    @Test func reloadIsReleasedOnProtocolErrorForOurCommand() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()

        client.emit(makeErrorEvent(message: "reload failed", commandId: client.sentCommands[0].id))
        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }

        #expect(controller.hasPendingChanges == true)
        #expect(controller.lastError == "reload failed")
    }

    @Test func reloadIgnoresProtocolErrorForOtherCommand() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()

        client.emit(makeErrorEvent(message: "other failed", commandId: "cmd-other"))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(controller.isReloading == true)
        #expect(controller.lastError == nil)
    }

    @Test func reloadAggregatesPluginsReloadedAcrossMultipleDaemons() async throws {
        let client = RecordingPickyAgentClient(broadcastDeliveredCount: 3)
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()

        // First two daemons reply. Aggregation must NOT complete yet because
        // expectedReplies is 3.
        client.emit(makeReloadedEvent(picky: true, reloaded: 2, aborted: 0, deferred: 0))
        client.emit(makeReloadedEvent(picky: false, reloaded: 1, aborted: 1, deferred: 0))
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(controller.isReloading == true)
        #expect(controller.lastResult == nil)

        // Third daemon replies — now the aggregation completes with summed counts.
        client.emit(makeReloadedEvent(picky: false, reloaded: 0, aborted: 0, deferred: 2))
        try await waitUntil(timeoutMs: 2_000) { controller.lastResult != nil }

        #expect(controller.isReloading == false)
        #expect(controller.hasPendingChanges == false)
        #expect(controller.lastResult?.pickyReloaded == true)
        #expect(controller.lastResult?.pickleReloadedCount == 3)
        #expect(controller.lastResult?.pickleAbortedCount == 1)
        #expect(controller.lastResult?.pickleDeferredCount == 2)
    }

    @Test func reloadCompletesWhenBroadcastDeliversToZeroDaemons() async throws {
        let client = RecordingPickyAgentClient(broadcastDeliveredCount: 0)
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()

        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }
        // No daemons received the command, so the summary should be all zeros
        // and the banner clears since no reload-applying changes are pending.
        #expect(controller.lastResult?.pickyReloaded == false)
        #expect(controller.lastResult?.pickleReloadedCount == 0)
        #expect(controller.hasPendingChanges == false)
    }

    @Test func reloadCompletesAfterActualDeliveredCountWhenSomeChildrenFail() async throws {
        // Router optimistically reports `broadcastTargetCount == 3` but the
        // parallel send only succeeded for 2 daemons. The controller should
        // tighten expectedReplies down to 2 and finish after two events.
        let client = RecordingPickyAgentClient(broadcastTargetCount: 3, broadcastDeliveredCount: 2)
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()

        client.emit(makeReloadedEvent(picky: false, reloaded: 1, aborted: 0, deferred: 0))
        client.emit(makeReloadedEvent(picky: true, reloaded: 0, aborted: 0, deferred: 0))
        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }

        #expect(controller.lastResult?.pickleReloadedCount == 1)
        #expect(controller.lastResult?.pickyReloaded == true)
    }

    @Test func reloadTimesOutWhenNoEventArrives() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client, reloadTimeoutSeconds: 0.05)
        controller.notePluginsChanged()

        await controller.reload()
        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }

        #expect(controller.lastError == L10n.t("status.extensions.reload.error.timeout"))
        #expect(controller.hasPendingChanges == true)
    }

    @Test func pluginsReloadedAfterTimeoutDoesNotOverrideError() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client, reloadTimeoutSeconds: 0.05)
        controller.notePluginsChanged()
        await controller.reload()
        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }

        client.emit(makeReloadedEvent(picky: true, reloaded: 1, aborted: 0, deferred: 0, requestId: client.sentCommands[0].id))
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(controller.lastError == L10n.t("status.extensions.reload.error.timeout"))
        #expect(controller.lastResult == nil)
        #expect(controller.isReloading == false)
    }

    @Test func pluginsReloadedWithMismatchedRequestIdIsIgnored() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client, reloadTimeoutSeconds: 5)
        controller.notePluginsChanged()
        await controller.reload()

        client.emit(makeReloadedEvent(picky: true, reloaded: 1, aborted: 0, deferred: 0, requestId: "cmd-other"))
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(controller.isReloading == true)
        #expect(controller.lastResult == nil)

        client.emit(makeReloadedEvent(picky: true, reloaded: 2, aborted: 0, deferred: 0, requestId: client.sentCommands[0].id))
        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }

        #expect(controller.lastResult?.pickleReloadedCount == 2)
        #expect(controller.lastError == nil)
    }

    @Test func watchdogCancelledOnSuccessfulReload() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client, reloadTimeoutSeconds: 0.2)
        controller.notePluginsChanged()
        await controller.reload()

        client.emit(makeReloadedEvent(picky: true, reloaded: 1, aborted: 0, deferred: 0, requestId: client.sentCommands[0].id))
        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(controller.lastError == nil)
        #expect(controller.lastResult?.pickleReloadedCount == 1)
    }

    @Test func stalePluginsReloadedAfterCancelDoesNotMutateState() async throws {
        let client = RecordingPickyAgentClient()
        let controller = PickyPluginReloadController(client: client)
        controller.notePluginsChanged()
        await controller.reload()

        client.emit(.disconnected)
        try await waitUntil(timeoutMs: 2_000) { controller.isReloading == false }

        client.emit(makeReloadedEvent(picky: true, reloaded: 1, aborted: 0, deferred: 0, requestId: client.sentCommands[0].id))
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(controller.lastResult == nil)
        #expect(controller.lastError == L10n.t("status.extensions.reload.error.disconnected"))
    }

    // MARK: - Helpers

    private func waitUntil(timeoutMs: Int, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !predicate() {
            if Date() > deadline {
                Issue.record("Timed out waiting for plugin reload event")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeReloadedEvent(picky: Bool, reloaded: Int, aborted: Int, deferred: Int, requestId: String? = nil) -> PickyEventEnvelope {
        let summary = PickyPluginsReloadedEvent(
            requestId: requestId,
            pickyReloaded: picky,
            pickleReloadedCount: reloaded,
            pickleAbortedCount: aborted,
            pickleDeferredCount: deferred
        )
        return PickyEventEnvelope(
            id: "evt-\(UUID().uuidString)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: .pluginsReloaded(summary)
        )
    }

    private func makeErrorEvent(message: String, commandId: String?) -> PickyEventEnvelope {
        PickyEventEnvelope(
            id: "evt-\(UUID().uuidString)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: .error(PickyErrorEvent(code: "reload_failed", message: message, commandId: commandId))
        )
    }
}

/// Stub client that records every command and exposes a hook to emit synthetic
/// events into the events stream from test code. `LocalStubPickyAgentClient`
/// does not record commands or expose its continuation, so we cannot reuse it.
@MainActor
private final class RecordingPickyAgentClient: PickyAgentClient {
    private(set) var sentCommands: [PickyCommandEnvelope] = []
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    /// Tells the controller how many daemons `broadcast` will try to deliver to.
    /// Defaults to 1 so existing single-daemon tests behave like before.
    private let configuredTargetCount: Int
    /// Reported as the actual delivery count returned by `broadcast`. Used to
    /// drive the aggregation "tighten expected replies" path.
    private let deliveredCount: Int

    init(broadcastTargetCount: Int = 1, broadcastDeliveredCount: Int? = nil) {
        self.configuredTargetCount = broadcastTargetCount
        self.deliveredCount = broadcastDeliveredCount ?? broadcastTargetCount
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        throw PickyAgentClientError.disconnected
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        sentCommands.append(command)
    }
    func disconnect() { continuation.finish() }

    var broadcastTargetCount: Int { configuredTargetCount }

    func broadcast(_ command: PickyCommandEnvelope) async throws -> Int {
        sentCommands.append(command)
        return deliveredCount
    }

    func emit(_ event: PickyClientEvent) {
        continuation.yield(event)
    }

    func emit(_ envelope: PickyEventEnvelope) {
        continuation.yield(.protocolEvent(envelope))
    }
}

@MainActor
private final class ThrowingPickyAgentClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        throw PickyAgentClientError.disconnected
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        throw PickyAgentClientError.disconnected
    }
    func disconnect() { continuation.finish() }
}
