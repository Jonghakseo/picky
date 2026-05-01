//
//  PickySessionSelectionStore.swift
//  Picky
//
//  Tiny persisted selection bridge shared by HUD and voice routing.
//

import Foundation

protocol PickySessionSelectionStoring: AnyObject {
    var selectedSessionID: String? { get set }
}

final class PickyUserDefaultsSessionSelectionStore: PickySessionSelectionStoring {
    static let shared = PickyUserDefaultsSessionSelectionStore()
    static let key = "PickySelectedSessionID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedSessionID: String? {
        get {
            guard let value = defaults.string(forKey: Self.key), !value.isEmpty else { return nil }
            return value
        }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}
