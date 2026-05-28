//
//  PickyFullscreenStateStore.swift
//  Picky
//
//  Persisted UI-only state for the fullscreen workspace shell.
//

import Combine
import Foundation

@MainActor
final class PickyFullscreenStateStore: ObservableObject {
    private enum Keys {
        static let isWorkInfoPanelVisible = "PickyFullscreen.isWorkInfoPanelVisible"
        static let selectedSessionID = "PickyFullscreen.selectedSessionID"
    }

    private let defaults: UserDefaults

    @Published var isWorkInfoPanelVisible: Bool {
        didSet {
            defaults.set(isWorkInfoPanelVisible, forKey: Keys.isWorkInfoPanelVisible)
        }
    }

    @Published var selectedSessionID: String? {
        didSet {
            if let selectedSessionID, !selectedSessionID.isEmpty {
                defaults.set(selectedSessionID, forKey: Keys.selectedSessionID)
            } else {
                defaults.removeObject(forKey: Keys.selectedSessionID)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.isWorkInfoPanelVisible) == nil {
            self.isWorkInfoPanelVisible = true
        } else {
            self.isWorkInfoPanelVisible = defaults.bool(forKey: Keys.isWorkInfoPanelVisible)
        }
        let persistedSessionID = defaults.string(forKey: Keys.selectedSessionID)
        self.selectedSessionID = persistedSessionID?.isEmpty == false ? persistedSessionID : nil
    }
}
