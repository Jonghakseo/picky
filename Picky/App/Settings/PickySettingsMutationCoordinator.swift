//
//  PickySettingsMutationCoordinator.swift
//  Picky
//

import Foundation

/// Serializes external settings mutations so callers never write a stale full
/// settings snapshot over unrelated runtime changes.
@MainActor
final class PickySettingsMutationCoordinator {
    private let store: PickySettingsStore

    private(set) var revision = 0

    init(store: PickySettingsStore = PickySettingsStore()) {
        self.store = store
    }

    /// Applies a narrow mutation to the latest persisted settings, then notifies
    /// runtime owners that they should refresh their settings-backed state.
    @discardableResult
    func applyPatch(_ mutate: (inout PickySettings) throws -> Void) throws -> Int {
        var updated = store.load()
        try mutate(&updated)
        try store.save(updated)
        NotificationCenter.default.post(name: .pickySettingsDidSave, object: nil)

        revision += 1
        return revision
    }
}
