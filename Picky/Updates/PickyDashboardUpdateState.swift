//
//  PickyDashboardUpdateState.swift
//  Picky
//
//  Pure state for the Hub dashboard update card. PickyUpdaterController feeds
//  Sparkle delegate callbacks into it; the dashboard only renders `card`.
//  See docs/prototypes/picky-update-card/index.html for the UX flow.
//

import Foundation

struct PickyDashboardUpdateState: Equatable {
    enum Phase: Equatable {
        case none
        /// Downloaded in the background; one click installs and relaunches.
        case readyToInstall
        case installing
        /// Found by a scheduled check while automatic download is off. The
        /// Sparkle update window finishes the job.
        case needsUpdateWindow
        case downloadFailed
    }

    enum Card: Equatable {
        case ready
        case installing
        case needsUpdateWindow
        case downloadFailed
    }

    private(set) var phase: Phase = .none
    private(set) var version: String?
    private(set) var releaseNotesURL: URL?
    private(set) var dismissedVersion: String?

    init(dismissedVersion: String? = nil) {
        self.dismissedVersion = dismissedVersion
    }

    /// The card the dashboard should show, or nil to hide it. "Later" hides
    /// the card for that version only; a newer version shows it again.
    var card: Card? {
        switch phase {
        case .none: return nil
        case .installing: return .installing
        case .readyToInstall, .needsUpdateWindow, .downloadFailed:
            if let version, version == dismissedVersion { return nil }
            switch phase {
            case .readyToInstall: return .ready
            case .needsUpdateWindow: return .needsUpdateWindow
            default: return .downloadFailed
            }
        }
    }

    mutating func updateReadyToInstall(version: String, releaseNotesURL: URL?) {
        guard phase != .installing else { return }
        phase = .readyToInstall
        self.version = version
        self.releaseNotesURL = releaseNotesURL
    }

    mutating func updateNeedsWindow(version: String, releaseNotesURL: URL?) {
        guard phase != .readyToInstall, phase != .installing else { return }
        phase = .needsUpdateWindow
        self.version = version
        self.releaseNotesURL = releaseNotesURL
    }

    mutating func downloadFailed(version: String) {
        guard phase != .readyToInstall, phase != .installing else { return }
        phase = .downloadFailed
        self.version = version
        releaseNotesURL = nil
    }

    /// Returns true when the caller should run Sparkle's immediate installer.
    mutating func beginInstall() -> Bool {
        guard phase == .readyToInstall else { return false }
        phase = .installing
        return true
    }

    /// The relaunch did not happen (for example, termination was cancelled).
    /// The downloaded update is still pending, so offer the button again.
    mutating func installDidNotRelaunch() {
        guard phase == .installing else { return }
        phase = .readyToInstall
    }

    /// The Sparkle update window took over (retry) or its session ended.
    mutating func handedOffToUpdateWindow() {
        guard phase == .needsUpdateWindow || phase == .downloadFailed else { return }
        phase = .none
        version = nil
        releaseNotesURL = nil
    }

    enum UpdateButtonAction: Equatable {
        case checkForUpdates
        case installReadyUpdate
    }

    /// What the "Check for Updates" buttons do, or nil to disable them.
    /// Once an update is downloaded, Sparkle stalls its update cycle and keeps
    /// `canCheckForUpdates` false until quit, so the buttons install the ready
    /// update instead. This holds even after "Later" hid the dashboard card.
    func updateButtonAction(sparkleCanCheckForUpdates: Bool) -> UpdateButtonAction? {
        switch phase {
        case .readyToInstall: return .installReadyUpdate
        case .installing: return nil
        case .none, .needsUpdateWindow, .downloadFailed:
            return sparkleCanCheckForUpdates ? .checkForUpdates : nil
        }
    }

    mutating func dismiss() {
        guard phase != .installing, let version else { return }
        dismissedVersion = version
    }
}

enum PickyUpdateRestartPolicy {
    /// Pickles whose current response a relaunch would interrupt. Idle,
    /// blocked, and finished Pickles resume from their saved conversation.
    static func interruptedPickleCount(statuses: [PickySessionStatus]) -> Int {
        statuses.count { $0 == .running || $0 == .queued }
    }
}
