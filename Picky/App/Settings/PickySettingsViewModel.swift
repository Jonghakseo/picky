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

    private let persistence: PickySettingsPersistenceCoordinator
    /// The latest durable snapshot. It becomes the next admission baseline
    /// once all currently queued panel saves have settled.
    private var savedBaseline: PickySettings
    /// The most recently admitted draft. Comparing against it makes a rapid
    /// change back to the durable value an explicit reversal of the
    /// preceding queued draft instead of an "unchanged" leaf.
    private var admissionBaseline: PickySettings
    @Published private(set) var isSaving = false
    private var activeSaveCount = 0

    init(
        store: PickySettingsStore = PickySettingsStore(),
        persistence: PickySettingsPersistenceCoordinator? = nil
    ) {
        self.persistence = persistence ?? .shared(for: store)
        let initialSettings = store.load()
        self.settings = initialSettings
        self.savedBaseline = initialSettings
        self.admissionBaseline = initialSettings
    }

    /// Synchronously admits the current draft into the settings FIFO. The
    /// completion reports durable success, so AppKit callers never show Saved
    /// merely because a background task was created.
    func save(completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let draft = settings
        let priorAdmissionBaseline = admissionBaseline
        admissionBaseline = draft
        beginSave()
        persistence.enqueue(
            notification: .settingsDidSave,
            mutation: { latest in
                latest = try PickySettingsSnapshotMerger.merge(
                    draft: draft,
                    baseline: priorAdmissionBaseline,
                    runtime: latest
                )
            },
            completion: { [weak self] result in
                guard let self else { return }
                completion(self.completeSave(result, draft: draft))
            }
        )
    }

    /// Durable convenience for tests and async callers that must await the
    /// atomic file transaction rather than use the completion-based UI path.
    @discardableResult
    func saveDurably() async -> Bool {
        let draft = settings
        let priorAdmissionBaseline = admissionBaseline
        admissionBaseline = draft
        beginSave()
        let result: Result<PickySettings, Error>
        do {
            result = .success(try await persistence.persist(notification: .settingsDidSave) { latest in
                latest = try PickySettingsSnapshotMerger.merge(
                    draft: draft,
                    baseline: priorAdmissionBaseline,
                    runtime: latest
                )
            })
        } catch {
            result = .failure(error)
        }
        return completeSave(result, draft: draft)
    }

    private func beginSave() {
        activeSaveCount += 1
        isSaving = true
    }

    private func completeSave(_ result: Result<PickySettings, Error>, draft: PickySettings) -> Bool {
        defer {
            activeSaveCount -= 1
            isSaving = activeSaveCount > 0
            if activeSaveCount == 0 {
                admissionBaseline = savedBaseline
            }
        }
        do {
            let committed = try result.get()
            // A user may continue editing while the write is in flight. Rebase
            // those post-admission edits onto the committed snapshot instead
            // of replacing them with the older captured draft.
            settings = try PickySettingsSnapshotMerger.merge(draft: settings, baseline: draft, runtime: committed)
            savedBaseline = committed
            validationError = nil
            return true
        } catch {
            validationError = error.localizedDescription
            return false
        }
    }

    /// Updates the draft shortcut spec, refusing collisions. Call `save` (or
    /// `saveDurably`) to persist it; the return value is not durable success.
    func updateShortcut(
        _ newSpec: PickyShortcutSpec,
        role: PickyShortcutRole
    ) -> Bool {
        guard newSpec.isValid else {
            validationError = "That shortcut combination isn’t valid."
            return false
        }
        let shortcuts: [PickyShortcutRole: PickyShortcutSpec] = [
            .pushToTalk: settings.pushToTalkShortcut,
            .quickInput: settings.quickInputShortcut,
            .focusPickle: settings.focusPickleShortcut,
        ]
        if PickyShortcutConflictPolicy.conflictingRole(
            for: newSpec,
            role: role,
            shortcuts: shortcuts
        ) != nil {
            validationError = "That shortcut conflicts with another action."
            return false
        }
        validationError = nil
        var updated = settings
        switch role {
        case .pushToTalk:
            updated.pushToTalkShortcut = newSpec
        case .quickInput:
            updated.quickInputShortcut = newSpec
        case .focusPickle:
            updated.focusPickleShortcut = newSpec
        }
        settings = updated
        return true
    }

    /// Restores all shortcut specs in the draft. Call `save` (or
    /// `saveDurably`) to persist them.
    @discardableResult
    func resetShortcutsToDefaults() -> Bool {
        validationError = nil
        var updated = settings
        updated.pushToTalkShortcut = .defaultPushToTalk
        updated.quickInputShortcut = .defaultQuickInput
        updated.focusPickleShortcut = .defaultFocusPickle
        settings = updated
        return true
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
