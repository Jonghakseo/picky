//
//  PickySettingsMutationCoordinator.swift
//  Picky
//

import Foundation

/// Serializes external settings mutations so callers never write a stale full
/// settings snapshot over unrelated runtime changes.
@MainActor
final class PickySettingsMutationCoordinator {
    private let persistence: PickySettingsPersistenceCoordinator

    private(set) var revision = 0

    init(
        store: PickySettingsStore = PickySettingsStore(),
        persistence: PickySettingsPersistenceCoordinator? = nil
    ) {
        self.persistence = persistence ?? .shared(for: store)
    }

    /// Applies a narrow mutation to the worker's latest persisted settings,
    /// then notifies runtime owners only after the atomic write succeeds.
    @discardableResult
    func applyPatch(_ mutate: @escaping PickySettingsPersistenceCoordinator.Mutation) async throws -> Int {
        try await applyPatchReturningSettings(mutate).revision
    }

    /// Returns the normalized snapshot actually written by the worker. Callers
    /// must derive response values from this result rather than capture mutable
    /// MainActor state inside the background mutation closure.
    func applyPatchReturningSettings(
        _ mutate: @escaping PickySettingsPersistenceCoordinator.Mutation
    ) async throws -> (settings: PickySettings, revision: Int) {
        let settings = try await persistence.persist(notification: .settingsDidSave, mutation: mutate)
        revision += 1
        return (settings, revision)
    }
}

/// Applies app-owned settings requests one at a time, including the optional
/// daemon acknowledgement for main-agent runtime settings. This keeps each
/// request's persisted value and revision stable while an earlier request is
/// suspended awaiting its acknowledgement.
@MainActor
final class PickySettingsControlHandler {
    typealias DockVisibilityApplier = (Bool, UInt32?) -> Void
    typealias MainAgentCommandApplier = (PickyCommandEnvelope) async -> String?

    private let settingsStore: PickySettingsStore
    private let mutationCoordinator: PickySettingsMutationCoordinator
    private let applyDockVisibility: DockVisibilityApplier
    private let applyMainAgentCommand: MainAgentCommandApplier
    private var pendingSetOperation: Task<Void, Never>?

    init(
        settingsStore: PickySettingsStore,
        mutationCoordinator: PickySettingsMutationCoordinator,
        applyDockVisibility: @escaping DockVisibilityApplier,
        applyMainAgentCommand: @escaping MainAgentCommandApplier
    ) {
        self.settingsStore = settingsStore
        self.mutationCoordinator = mutationCoordinator
        self.applyDockVisibility = applyDockVisibility
        self.applyMainAgentCommand = applyMainAgentCommand
    }

    func handle(_ request: PickySettingsRequest) async throws -> JSONValue {
        switch request.action {
        case .list:
            let settings = settingsStore.load()
            let entries = try PickySettingsCLIExposure.entries.map { entry in
                try PickySettingsCLIExposure.metadataPayload(
                    for: entry,
                    currentValue: PickySettingsCLIExposure.currentValue(for: entry.key, in: settings)
                )
            }
            return .object(["entries": .array(entries)])
        case .get:
            guard let key = request.key else {
                throw PickySettingsCLIExposureError(code: "SETTINGS_KEY_REQUIRED", message: "A Picky setting key is required.")
            }
            return .object([
                "key": .string(key),
                "value": try PickySettingsCLIExposure.currentValue(for: key, in: settingsStore.load())
            ])
        case .set:
            return try await enqueueSet(request)
        }
    }

    private func enqueueSet(_ request: PickySettingsRequest) async throws -> JSONValue {
        let precedingOperation = pendingSetOperation
        return try await withCheckedThrowingContinuation { continuation in
            let operation = Task { @MainActor [weak self] in
                _ = await precedingOperation?.result
                guard let self else {
                    continuation.resume(throwing: PickyAgentClientRouterError.routerUnavailable)
                    return
                }
                do {
                    continuation.resume(returning: try await self.applySet(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            pendingSetOperation = operation
        }
    }

    private func applySet(_ request: PickySettingsRequest) async throws -> JSONValue {
        guard let key = request.key, let value = request.value else {
            throw PickySettingsCLIExposureError(code: "SETTINGS_KEY_AND_VALUE_REQUIRED", message: "A Picky setting key and value are required.")
        }
        let entry = try PickySettingsCLIExposure.entry(for: key)
        try PickySettingsCLIExposure.validateAccess(for: entry, caller: request.caller)
        if let displayId = request.displayId {
            guard key == "hud.dockVisible", UInt32(displayId) != nil else {
                throw PickySettingsCLIExposureError(code: "SETTINGS_INVALID_DISPLAY_ID", message: "hud.dockVisible display IDs must be unsigned integers.")
            }
        }

        let committed = try await mutationCoordinator.applyPatchReturningSettings { settings in
            _ = try PickySettingsCLIExposure.apply(
                key: key,
                value: value,
                toggle: request.toggle ?? false,
                displayId: request.displayId,
                to: &settings
            )
        }
        let persistedValue = try PickySettingsCLIExposure.currentValue(
            for: key,
            in: committed.settings,
            displayId: request.displayId
        )
        let revision = committed.revision

        if key == "hud.dockVisible", case .bool(let visible) = persistedValue {
            applyDockVisibility(visible, request.displayId.flatMap(UInt32.init))
        }

        let applicationError = await applyMainAgentSetting(key: key, persistedValue: persistedValue)
        var result: [String: JSONValue] = [
            "key": .string(key),
            "value": persistedValue,
            "persisted": .bool(true),
            "applied": .bool(applicationError == nil),
            "restartRequired": .bool(entry.restartRequired),
            "revision": .number(Double(revision))
        ]
        if let applicationError {
            result["errorMessage"] = .string(applicationError)
        }
        return .object(result)
    }

    private func applyMainAgentSetting(key: String, persistedValue: JSONValue) async -> String? {
        let command: PickyCommandEnvelope
        switch key {
        case "mainAgent.model":
            guard case .string(let model) = persistedValue else { return "Picky saved an invalid main agent model value." }
            command = PickyCommandEnvelope(type: .setMainAgentModel, mainAgentModelPattern: model)
        case "mainAgent.thinkingLevel":
            guard case .string(let rawThinkingLevel) = persistedValue,
                  let thinkingLevel = PickyMainAgentThinkingLevel(rawValue: rawThinkingLevel) else {
                return "Picky saved an invalid main agent thinking level."
            }
            command = PickyCommandEnvelope(type: .setMainAgentThinkingLevel, mainAgentThinkingLevel: thinkingLevel)
        default:
            return nil
        }
        return await applyMainAgentCommand(command)
    }

}
