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
            try store.save(settings)
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
            validationError = "단축키 조합이 올바르지 않습니다."
            return false
        }
        if newSpec.conflicts(with: other) {
            validationError = "다른 단축키와 중복됩니다."
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
