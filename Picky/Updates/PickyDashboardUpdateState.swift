//
//  PickyDashboardUpdateState.swift
//  Picky
//
//  Pure state for the Hub dashboard update card. PickyUpdaterController feeds
//  Sparkle delegate and user-driver callbacks into it; the dashboard only
//  renders `card`. See docs/prototypes/picky-update-card/index.html.
//

import Foundation

struct PickyDashboardUpdateState: Equatable {
    enum Phase: Equatable {
        case none
        /// A check the user asked for is running.
        case checking
        /// That check found nothing. Shown briefly, then cleared.
        case upToDate
        /// A newer version exists on the appcast. Nothing is downloaded yet.
        case available
        /// The user asked to update: Sparkle is fetching the archive.
        case downloading(progress: Double?)
        /// Downloaded and waiting for the user to accept the relaunch.
        case readyToRelaunch
        case installing
        case failed
    }

    enum Card: Equatable {
        case checking
        case upToDate
        case available
        case downloading(progress: Double?)
        case ready
        case installing
        case failed
    }

    private(set) var phase: Phase = .none
    private(set) var version: String?
    private(set) var releaseNotesURL: URL?
    /// The appcast item only links to a page and must not be downloaded.
    private(set) var isInformationOnly: Bool = false
    private(set) var dismissedVersion: String?

    init(dismissedVersion: String? = nil) {
        self.dismissedVersion = dismissedVersion
    }

    /// The card the dashboard should show, or nil to hide it. "Later" hides
    /// the card for that version only; a newer version shows it again.
    var card: Card? {
        switch phase {
        case .none: return nil
        case .checking: return .checking
        case .upToDate: return .upToDate
        case .downloading(let progress): return .downloading(progress: progress)
        case .installing: return .installing
        case .available, .readyToRelaunch, .failed:
            if let version, version == dismissedVersion { return nil }
            switch phase {
            case .available: return .available
            case .readyToRelaunch: return .ready
            default: return .failed
            }
        }
    }

    /// True while nothing is being downloaded or installed, so a new check
    /// result may replace what the card shows.
    private var isIdle: Bool {
        switch phase {
        case .none, .checking, .upToDate, .available, .failed: return true
        case .downloading, .readyToRelaunch, .installing: return false
        }
    }

    /// A check the user asked for started. It clears "Later" so the result is
    /// always visible to the person who just asked for it.
    mutating func checkStarted() {
        guard isIdle else { return }
        dismissedVersion = nil
        phase = .checking
    }

    mutating func updateAvailable(version: String, releaseNotesURL: URL?, isInformationOnly: Bool = false) {
        guard isIdle else { return }
        phase = .available
        self.version = version
        self.releaseNotesURL = releaseNotesURL
        self.isInformationOnly = isInformationOnly
    }

    /// The feed has nothing newer. Only a check the user asked for reports it;
    /// a scheduled check silently clears the card.
    mutating func noUpdateFound(userInitiated: Bool) {
        guard isIdle else { return }
        phase = userInitiated ? .upToDate : .none
        version = nil
        releaseNotesURL = nil
        isInformationOnly = false
    }

    /// Clears the short-lived "up to date" notice.
    mutating func clearUpToDateNotice() {
        guard phase == .upToDate else { return }
        phase = .none
    }

    /// Sparkle started fetching this version. The version comes from the check
    /// that just ran, so it can be newer than what the card advertised.
    mutating func downloadStarted(version: String, releaseNotesURL: URL?) {
        phase = .downloading(progress: nil)
        self.version = version
        self.releaseNotesURL = releaseNotesURL
        isInformationOnly = false
        dismissedVersion = nil
    }

    mutating func downloadProgress(_ fraction: Double?) {
        guard case .downloading = phase else { return }
        phase = .downloading(progress: fraction.map { min(max($0, 0), 1) })
    }

    /// The archive is on disk. Sparkle waits for the relaunch answer, so the
    /// card keeps offering the install until the user accepts it.
    mutating func readyToRelaunch(version: String?) {
        guard phase != .installing else { return }
        phase = .readyToRelaunch
        if let version { self.version = version }
        isInformationOnly = false
    }

    /// Returns true when the caller should tell Sparkle to install and relaunch.
    mutating func beginInstall() -> Bool {
        guard phase == .readyToRelaunch else { return false }
        phase = .installing
        return true
    }

    /// The relaunch did not happen (for example, termination was cancelled).
    /// The downloaded update is still pending, so offer the button again.
    mutating func installDidNotRelaunch() {
        guard phase == .installing else { return }
        phase = .readyToRelaunch
    }

    mutating func updateFailed(version: String?) {
        guard phase != .installing else { return }
        phase = .failed
        if let version { self.version = version }
        releaseNotesURL = nil
        isInformationOnly = false
    }

    /// Sparkle tore down the session without installing. Anything still shown
    /// as in-flight falls back to the plain "update available" notice.
    mutating func updateSessionEnded() {
        switch phase {
        case .checking, .downloading, .readyToRelaunch, .installing:
            phase = version == nil ? .none : .available
        case .none, .upToDate, .available, .failed:
            break
        }
    }

    enum UpdateButtonAction: Equatable {
        /// Read the feed only, to refresh what the card shows.
        case checkForUpdates
        /// Check again and install whatever newest version that check returns.
        case startUpdate
        /// The archive is already downloaded; install and relaunch.
        case installReadyUpdate
        /// Information-only item: open the page instead of downloading.
        case openReleaseNotes
    }

    /// What the update buttons do, or nil to disable them. Once Sparkle holds
    /// a downloaded update it keeps `canCheckForUpdates` false until quit, so
    /// the install action does not depend on it.
    func updateButtonAction(sparkleCanCheckForUpdates: Bool) -> UpdateButtonAction? {
        switch phase {
        case .readyToRelaunch:
            return .installReadyUpdate
        case .available:
            if isInformationOnly { return .openReleaseNotes }
            return sparkleCanCheckForUpdates ? .startUpdate : nil
        case .failed:
            guard sparkleCanCheckForUpdates else { return nil }
            return version == nil ? .checkForUpdates : .startUpdate
        case .checking, .downloading, .installing:
            return nil
        case .none, .upToDate:
            return sparkleCanCheckForUpdates ? .checkForUpdates : nil
        }
    }

    mutating func dismiss() {
        switch phase {
        case .upToDate:
            phase = .none
        case .available, .failed, .readyToRelaunch:
            guard let version else { return }
            dismissedVersion = version
        case .none, .checking, .downloading, .installing:
            break
        }
    }
}

enum PickyUpdateRestartPolicy {
    /// Pickles whose current response a relaunch would interrupt. Idle,
    /// blocked, and finished Pickles resume from their saved conversation.
    static func interruptedPickleCount(statuses: [PickySessionStatus]) -> Int {
        statuses.count { $0 == .running || $0 == .queued }
    }
}
