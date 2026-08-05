//
//  PickySessionSelectionStore.swift
//  Picky
//
//  Tiny persisted selection/archive bridge shared by HUD and voice routing.
//

import Foundation

extension Notification.Name {
    static let pickyVoiceFollowUpTargetChanged = Notification.Name("pickyVoiceFollowUpTargetChanged")
    static let pickyScreenContextTargetChanged = Notification.Name("pickyScreenContextTargetChanged")
    static let pickyComposerDraftAppendRequested = Notification.Name("pickyComposerDraftAppendRequested")
}

enum PickyVoiceFollowUpTargetNotification {
    static let sessionIDKey = "sessionID"
}

enum PickyScreenContextTargetNotification {
    static let sessionIDKey = "sessionID"
    static let stickyKey = "sticky"
    static let labelKey = "label"
}

enum PickyComposerDraftAppendNotification {
    static let sessionIDKey = "sessionID"
    static let textKey = "text"
}

protocol PickySessionSelectionStoring: AnyObject {
    var selectedSessionID: String? { get set }
    var hoveredVoiceFollowUpSessionID: String? { get set }
    var screenContextTargetSessionID: String? { get set }
    /// Monotonic identity of the current armed-target semantics. Voice input
    /// snapshots this value so completion cannot clear a target re-armed later.
    var screenContextTargetRevision: UInt64 { get }
    /// Whether the currently armed screen-context target should persist across
    /// follow-up/steer dispatches. `false` means the existing one-shot behavior;
    /// `true` keeps the same Pickle armed until the user clicks it again or
    /// arms another. Always cleared when `screenContextTargetSessionID` is nil.
    var screenContextTargetSticky: Bool { get set }
    /// Atomically updates the armed Pickle and its sticky flag. Implementations
    /// must emit a single `pickyScreenContextTargetChanged` notification when
    /// either value changes.
    func setScreenContextTarget(sessionID: String?, sticky: Bool)
}

extension PickySessionSelectionStoring {
    /// Test/legacy stores that do not track revisions retain the previous
    /// compare-by-session behavior. Production overrides this with a counter.
    var screenContextTargetRevision: UInt64 { 0 }

    /// Default fallback so legacy call sites (`store.screenContextTargetSessionID = id`)
    /// keep the one-shot semantics they always had.
    func setScreenContextTarget(sessionID: String?) {
        setScreenContextTarget(sessionID: sessionID, sticky: false)
    }
}

/// Optional presentation metadata for the transient armed target. Routing
/// remains session-ID based; this lets Quick Input truthfully name the target.
protocol PickyScreenContextTargetLabelStoring: AnyObject {
    var screenContextTargetLabel: String? { get }
    func setScreenContextTarget(sessionID: String?, sticky: Bool, label: String?)
}

protocol PickySessionArchiveStoring: AnyObject {
    var archivedSessionIDs: Set<String> { get set }
    var manuallyArchivedSessionIDs: Set<String> { get set }
}

/// Persists the dock's manual reorder of Pickle icons. Order matches the
/// underlying `sessions` array (newest-first), so a new session prepended
/// at index 0 lands on the visually-end slot.
protocol PickySessionManualOrderStoring: AnyObject {
    var manualOrder: [String] { get set }
}

final class PickyUserDefaultsSessionSelectionStore: PickySessionSelectionStoring, PickyScreenContextTargetLabelStoring {
    static let shared = PickyUserDefaultsSessionSelectionStore()
    static let key = "PickySelectedSessionID"

    private let defaults: UserDefaults
    private var transientHoveredVoiceFollowUpSessionID: String?
    private var transientScreenContextTargetSessionID: String?
    private var transientScreenContextTargetSticky: Bool = false
    private var transientScreenContextTargetLabel: String?
    private var transientScreenContextTargetRevision: UInt64 = 0

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

    var screenContextTargetSessionID: String? {
        get { transientScreenContextTargetSessionID }
        set { setScreenContextTarget(sessionID: newValue, sticky: false) }
    }

    var screenContextTargetLabel: String? { transientScreenContextTargetLabel }
    var screenContextTargetRevision: UInt64 { transientScreenContextTargetRevision }

    var screenContextTargetSticky: Bool {
        get { transientScreenContextTargetSticky }
        set {
            let next = transientScreenContextTargetSessionID == nil ? false : newValue
            guard transientScreenContextTargetSticky != next else { return }
            transientScreenContextTargetSticky = next
            transientScreenContextTargetRevision &+= 1
            postScreenContextTargetNotification()
        }
    }

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        setScreenContextTarget(sessionID: sessionID, sticky: sticky, label: nil)
    }

    func setScreenContextTarget(sessionID: String?, sticky: Bool, label: String?) {
        let normalized = sessionID?.isEmpty == true ? nil : sessionID
        let normalizedSticky = normalized == nil ? false : sticky
        let normalizedLabel = normalized == nil ? nil : label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let semanticsChanged = transientScreenContextTargetSessionID != normalized
            || transientScreenContextTargetSticky != normalizedSticky
        let labelChanged = transientScreenContextTargetLabel != normalizedLabel
        guard semanticsChanged || labelChanged else { return }
        transientScreenContextTargetSessionID = normalized
        transientScreenContextTargetSticky = normalizedSticky
        transientScreenContextTargetLabel = normalizedLabel
        if semanticsChanged {
            transientScreenContextTargetRevision &+= 1
        }
        postScreenContextTargetNotification()
    }

    private func postScreenContextTargetNotification() {
        var userInfo: [String: Any] = [
            PickyScreenContextTargetNotification.stickyKey: transientScreenContextTargetSticky
        ]
        if let id = transientScreenContextTargetSessionID {
            userInfo[PickyScreenContextTargetNotification.sessionIDKey] = id
        }
        if let label = transientScreenContextTargetLabel {
            userInfo[PickyScreenContextTargetNotification.labelKey] = label
        }
        NotificationCenter.default.post(
            name: .pickyScreenContextTargetChanged,
            object: nil,
            userInfo: userInfo
        )
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

final class PickyUserDefaultsSessionManualOrderStore: PickySessionManualOrderStoring {
    static let shared = PickyUserDefaultsSessionManualOrderStore()
    static let key = "PickyManualSessionOrder"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var manualOrder: [String] {
        get { defaults.stringArray(forKey: Self.key) ?? [] }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.key)
            } else {
                defaults.set(newValue, forKey: Self.key)
            }
        }
    }
}
