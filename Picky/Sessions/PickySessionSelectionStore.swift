//
//  PickySessionSelectionStore.swift
//  Picky
//
//  Tiny persisted selection/archive bridge shared by HUD and voice routing.
//

import Foundation

protocol PickySessionSelectionStoring: AnyObject {
    var selectedSessionID: String? { get set }
    var hoveredVoiceFollowUpSessionID: String? { get set }
}

protocol PickySessionArchiveStoring: AnyObject {
    var archivedSessionIDs: Set<String> { get set }
    var didMigrateDetachedRuntimeAutoArchive: Bool { get set }
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
    static let detachedRuntimeAutoArchiveMigrationKey = "PickyDidMigrateDetachedRuntimeAutoArchive"

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

    var didMigrateDetachedRuntimeAutoArchive: Bool {
        get { defaults.bool(forKey: Self.detachedRuntimeAutoArchiveMigrationKey) }
        set { defaults.set(newValue, forKey: Self.detachedRuntimeAutoArchiveMigrationKey) }
    }
}
