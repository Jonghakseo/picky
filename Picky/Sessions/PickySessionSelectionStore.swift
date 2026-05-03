//
//  PickySessionSelectionStore.swift
//  Picky
//
//  Tiny persisted selection/archive bridge shared by HUD and voice routing.
//

import Foundation

extension Notification.Name {
    static let pickyVoiceFollowUpTargetChanged = Notification.Name("pickyVoiceFollowUpTargetChanged")
}

enum PickyVoiceFollowUpTargetNotification {
    static let sessionIDKey = "sessionID"
}

protocol PickySessionSelectionStoring: AnyObject {
    var selectedSessionID: String? { get set }
    var hoveredVoiceFollowUpSessionID: String? { get set }
}

protocol PickySessionArchiveStoring: AnyObject {
    var archivedSessionIDs: Set<String> { get set }
    var manuallyArchivedSessionIDs: Set<String> { get set }
}

final class PickyUserDefaultsSessionSelectionStore: PickySessionSelectionStoring {
    static let shared = PickyUserDefaultsSessionSelectionStore()
    static let key = "PickySelectedSessionID"

    private let defaults: UserDefaults
    private var transientHoveredVoiceFollowUpSessionID: String?

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

    var hoveredVoiceFollowUpSessionID: String? {
        get { transientHoveredVoiceFollowUpSessionID }
        set { transientHoveredVoiceFollowUpSessionID = newValue?.isEmpty == true ? nil : newValue }
    }
}

final class PickyUserDefaultsSessionArchiveStore: PickySessionArchiveStoring {
    static let shared = PickyUserDefaultsSessionArchiveStore()
    static let key = "PickyArchivedSessionIDs"
    static let manuallyArchivedKey = "PickyManuallyArchivedSessionIDs"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var archivedSessionIDs: Set<String> {
        get {
            Set(defaults.stringArray(forKey: Self.key) ?? [])
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.key)
            } else {
                defaults.set(Array(newValue).sorted(), forKey: Self.key)
            }
        }
    }

    var manuallyArchivedSessionIDs: Set<String> {
        get {
            Set(defaults.stringArray(forKey: Self.manuallyArchivedKey) ?? [])
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.manuallyArchivedKey)
            } else {
                defaults.set(Array(newValue).sorted(), forKey: Self.manuallyArchivedKey)
            }
        }
    }
}
