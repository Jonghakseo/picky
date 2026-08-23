//
//  PickySettingsViewModel.swift
//  Picky
//

import Combine
import Foundation

extension Notification.Name {
    static let pickySettingsDidSave = Notification.Name("pickySettingsDidSave")
}

@MainActor
final class PickySettingsViewModel: ObservableObject {
    @Published var settings: PickySettings
    @Published private(set) var validationError: String?

    private let store: PickySettingsStore
    /// The disk snapshot from when the panel opened or last saved. It lets a
    /// later save distinguish fields edited in this panel from stale fields.
    private var savedBaseline: PickySettings

    init(store: PickySettingsStore = PickySettingsStore()) {
        self.store = store
        let initialSettings = store.load()
        self.settings = initialSettings
        self.savedBaseline = initialSettings
    }

    func save() -> Bool {
        do {
            // The settings panel holds a cached snapshot while other runtime
            // owners (including the CLI settings bridge) can update the file.
            // Merge only values changed from this panel's baseline; untouched
            // leaves retain the newest disk-backed value.
            let updated = try PickySettingsSnapshotMerger.merge(
                draft: settings,
                baseline: savedBaseline,
                runtime: store.load()
            )
            try store.save(updated)
            let savedSettings = store.load()
            settings = savedSettings
            savedBaseline = savedSettings
            validationError = nil
            NotificationCenter.default.post(name: .pickySettingsDidSave, object: nil)
            return true
        } catch {
            validationError = error.localizedDescription
            return false
        }
    }

    /// Updates one of the two shortcut specs, refusing if the new spec would
    /// collide with the other shortcut. Returns true on success.
    func updateShortcut(
        _ newSpec: PickyShortcutSpec,
        keyPath: WritableKeyPath<PickySettings, PickyShortcutSpec>,
        conflictsWith other: PickyShortcutSpec
    ) -> Bool {
        guard newSpec.isValid else {
            validationError = "That shortcut combination isn’t valid."
            return false
        }
        if newSpec.conflicts(with: other) {
            validationError = "That shortcut conflicts with the other one."
            return false
        }
        validationError = nil
        var updated = settings
        updated[keyPath: keyPath] = newSpec
        settings = updated
        return save()
    }

    /// Restores both shortcut specs to their default values.
    @discardableResult
    func resetShortcutsToDefaults() -> Bool {
        validationError = nil
        var updated = settings
        updated.pushToTalkShortcut = .defaultPushToTalk
        updated.quickInputShortcut = .defaultQuickInput
        settings = updated
        return save()
    }
}

/// Performs a leaf-level three-way merge between the panel's saved baseline,
/// its current draft, and the latest persisted settings. Codable JSON keeps
/// this in sync as settings fields are added without maintaining a second,
/// error-prone list of writable fields.
private enum PickySettingsSnapshotMerger {
    static func merge(
        draft: PickySettings,
        baseline: PickySettings,
        runtime: PickySettings
    ) throws -> PickySettings {
        let merged = mergeValue(
            try jsonObject(for: draft),
            baseline: try jsonObject(for: baseline),
            runtime: try jsonObject(for: runtime)
        )
        guard JSONSerialization.isValidJSONObject(merged) else {
            throw PickySettingsSnapshotMergeError.invalidJSONObject
        }
        return try JSONDecoder().decode(
            PickySettings.self,
            from: JSONSerialization.data(withJSONObject: merged)
        )
    }

    private static func jsonObject(for settings: PickySettings) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
    }

    private static func mergeValue(_ draft: Any, baseline: Any, runtime: Any) -> Any {
        guard
            let draftObject = draft as? [String: Any],
            let baselineObject = baseline as? [String: Any],
            let runtimeObject = runtime as? [String: Any]
        else {
            return valuesAreEqual(draft, baseline) ? runtime : draft
        }

        var merged = runtimeObject
        for (key, draftValue) in draftObject {
            guard let baselineValue = baselineObject[key] else {
                // The panel added this key after its baseline snapshot, so its
                // explicit draft value is the only value to retain.
                merged[key] = draftValue
                continue
            }
            guard let runtimeValue = runtimeObject[key] else {
                // Runtime deliberately removed this existing key (for example,
                // a per-display dock visibility override). Keep that deletion
                // unless the panel changed the same key after opening.
                if !valuesAreEqual(draftValue, baselineValue) {
                    merged[key] = draftValue
                }
                continue
            }
            merged[key] = mergeValue(draftValue, baseline: baselineValue, runtime: runtimeValue)
        }
        return merged
    }

    private static func valuesAreEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else {
            return false
        }
        return lhs.isEqual(rhs)
    }
}

private enum PickySettingsSnapshotMergeError: Error {
    case invalidJSONObject
}
