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

    private func makeReloadedEvent(picky: Bool, reloaded: Int, aborted: Int, deferred: Int) -> PickyEventEnvelope {
        let summary = PickyPluginsReloadedEvent(
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
}

/// Stub client that records every command and exposes a hook to emit synthetic
/// events into the events stream from test code. `LocalStubPickyAgentClient`
/// does not record commands or expose its continuation, so we cannot reuse it.
@MainActor
private final class RecordingPickyAgentClient: PickyAgentClient {
    private(set) var sentCommands: [PickyCommandEnvelope] = []
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
        sentCommands.append(command)
    }
    func disconnect() { continuation.finish() }

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
