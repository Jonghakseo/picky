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

    init(store: PickySettingsStore = PickySettingsStore()) {
        self.store = store
        self.settings = store.load()
    }

    func save() -> Bool {
        do {
            var updated = settings
            // The settings panel edits a cached full settings snapshot, while manual Pickle
            // creation updates recentPickleCwds/pinnedPickleCwds in the shared settings file at runtime.
            // Preserve the latest disk-backed folder lists so a later Settings save cannot clobber them.
            let runtimeSettings = store.load()
            updated.recentPickleCwds = runtimeSettings.recentPickleCwds
            updated.pinnedPickleCwds = runtimeSettings.pinnedPickleCwds
            try store.save(updated)
            settings = store.load()
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
