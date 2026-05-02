//
//  PickySettingsViewModel.swift
//  Picky
//

import Combine
import Foundation

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
            validationError = nil
            return true
        } catch {
            validationError = error.localizedDescription
            return false
        }
    }
}
