//
//  PickySettingsControlHandlerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
private final class DelayedMainAgentSettingApplier {
    private var firstCommandWaiter: CheckedContinuation<Void, Never>?
    private var firstCommandCompletion: CheckedContinuation<Void, Never>?
    private(set) var commandCount = 0

    func apply(_ command: PickyCommandEnvelope) async -> String? {
        commandCount += 1
        if commandCount == 1 {
            firstCommandWaiter?.resume()
            firstCommandWaiter = nil
            await withCheckedContinuation { firstCommandCompletion = $0 }
        }
        return nil
    }

    func waitUntilFirstCommandStarts() async {
        guard commandCount == 0 else { return }
        await withCheckedContinuation { firstCommandWaiter = $0 }
    }

    func completeFirstCommand() {
        firstCommandCompletion?.resume()
        firstCommandCompletion = nil
    }
}

struct PickySettingsControlHandlerTests {
    @MainActor
    @Test func serializesMainAgentSettingsUntilAcknowledgementAndReturnsEachPersistedValue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-control-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let settingsStore = PickySettingsStore(appSupportRoot: root)
        var initialSettings = PickySettings.defaults(appSupportRoot: root)
        initialSettings.defaultCwd = project.path
        initialSettings.mainAgentCwd = project.path
        initialSettings.worktreeParent = project.path
        try settingsStore.save(initialSettings)

        let applier = DelayedMainAgentSettingApplier()
        let handler = PickySettingsControlHandler(
            settingsStore: settingsStore,
            mutationCoordinator: PickySettingsMutationCoordinator(store: settingsStore),
            applyDockVisibility: { _, _ in },
            applyMainAgentCommand: { command in await applier.apply(command) }
        )
        let requestA = PickySettingsRequest(
            requestId: "request-a",
            action: .set,
            key: "mainAgent.model",
            value: .string("model/a"),
            toggle: false,
            displayId: nil,
            caller: nil
        )
        let requestB = PickySettingsRequest(
            requestId: "request-b",
            action: .set,
            key: "mainAgent.model",
            value: .string("model/b"),
            toggle: false,
            displayId: nil,
            caller: nil
        )

        let firstResultTask = Task { @MainActor in try await handler.handle(requestA) }
        await applier.waitUntilFirstCommandStarts()
        let secondResultTask = Task { @MainActor in try await handler.handle(requestB) }
        await Task.yield()

        #expect(applier.commandCount == 1)
        #expect(settingsStore.load().mainAgentModelPattern == "model/a")

        applier.completeFirstCommand()
        let firstResult = try await firstResultTask.value
        let secondResult = try await secondResultTask.value

        let first = try #require(firstResult.objectValue)
        let second = try #require(secondResult.objectValue)
        #expect(first["value"] == .string("model/a"))
        #expect(first["revision"] == .number(1))
        #expect(second["value"] == .string("model/b"))
        #expect(second["revision"] == .number(2))
        #expect(settingsStore.load().mainAgentModelPattern == "model/b")
    }

    @MainActor
    @Test func returnsCommittedDisplaySpecificDockVisibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-control-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let settingsStore = PickySettingsStore(appSupportRoot: root)
        var initialSettings = PickySettings.defaults(appSupportRoot: root)
        initialSettings.defaultCwd = project.path
        initialSettings.mainAgentCwd = project.path
        initialSettings.worktreeParent = project.path
        initialSettings.hudDockVisible = true
        try settingsStore.save(initialSettings)

        let handler = PickySettingsControlHandler(
            settingsStore: settingsStore,
            mutationCoordinator: PickySettingsMutationCoordinator(store: settingsStore),
            applyDockVisibility: { _, _ in },
            applyMainAgentCommand: { _ in nil }
        )
        let result = try await handler.handle(PickySettingsRequest(
            requestId: "display-visibility",
            action: .set,
            key: "hud.dockVisible",
            value: .bool(false),
            toggle: false,
            displayId: "42",
            caller: nil
        ))

        let payload = try #require(result.objectValue)
        #expect(payload["value"] == .bool(false))
        #expect(settingsStore.load().hudDockVisible)
        #expect(settingsStore.load().hudDockVisibilityByDisplayID["42"] == false)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}
