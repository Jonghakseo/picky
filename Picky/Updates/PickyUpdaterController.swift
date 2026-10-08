//
//  PickyUpdaterController.swift
//  Picky
//
//  Sparkle 2 controller. Picky owns the update schedule: a periodic check
//  reads version information only, and the Hub's Update button runs a fresh
//  check whose newest item is downloaded and installed through
//  PickyUpdateUserDriver. Nothing is downloaded before the user asks.
//  See docs/auto-update.md for the design.
//

import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
final class PickyUpdaterController: NSObject, ObservableObject {
    /// Mirrors `SPUUpdater.canCheckForUpdates` so SwiftUI can disable the
    /// update buttons while a check is already in flight.
    @Published private(set) var canCheckForUpdates: Bool = false
    /// Reflects the last appcast fetch the SPUUpdater performed.
    @Published private(set) var lastUpdateCheckDate: Date?
    /// Drives the Hub dashboard update card.
    @Published private(set) var dashboardUpdate: PickyDashboardUpdateState
    // Sparkle reads `allowedChannels(for:)` from non-main threads, so the
    // currently allowed channel set is held behind a lock and updated from
    // the main actor whenever the user flips the preference. The pair is
    // exposed as nonisolated so the lock itself can be acquired off-main —
    // the NSLock is what makes concurrent access safe.
    private nonisolated let channelLock = NSLock()
    private nonisolated(unsafe) var lockedAllowedChannels: Set<String> = []

    private let releaseChannel: String
    private let userDriver = PickyUpdateUserDriver()
    private var updater: SPUUpdater?
    private var engine: (any PickyUpdaterEngine)?

    var updateChannelDisplayName: String {
        switch releaseChannel {
        case "stable": return PickyUpdateChannel.stable.displayName
        case "beta": return PickyUpdateChannel.beta.displayName
        default: return Self.channelLabel(forReleaseChannel: releaseChannel)
        }
    }
    /// Picky bundles `picky-agentd` under `Contents/Resources/agentd`. Sparkle
    /// replaces the entire .app on relaunch, which would crash the running Node
    /// child with `ENOENT: uv_cwd`. Hosts hook this closure to stop the daemon
    /// before Sparkle swaps the bundle. See docs/auto-update.md.
    var willRelaunchApplication: (@MainActor () -> Void)?
    /// Set by the host to confirm before the relaunch interrupts Pickles
    /// mid-response. Without it the update installs as soon as it is ready.
    var confirmReadyUpdateInstall: (@MainActor () -> Void)?

    private enum CheckIntent {
        /// Picky's own timer: information only, no card unless something is found.
        case scheduled
        /// The user pressed a check button: information only, with feedback.
        case userInformation
        /// The user pressed Update: download and install what this check finds.
        case userInstall
    }

    private var cancellables: Set<AnyCancellable> = []
    private var activeIntent: CheckIntent?
    private var pendingUserInstall = false
    private var relaunchReply: ((PickyUpdateReply) -> Void)?
    private var retryTerminatingApplication: (() -> Void)?
    private var automaticChecksEnabled: Bool
    private var scheduledCheckTask: Task<Void, Never>?
    private var installFallbackTask: Task<Void, Never>?
    private var upToDateNoticeTask: Task<Void, Never>?
    private let defaults: UserDefaults

    static let dismissedUpdateVersionDefaultsKey = "PickyDashboardDismissedUpdateVersion"
    /// Matches the `SUScheduledCheckInterval` Picky shipped with Sparkle's own
    /// scheduler; Picky now runs the timer so checks stay information-only.
    static let scheduledCheckInterval: Duration = .seconds(4 * 60 * 60)
    /// Gives launch work time to settle before the first check.
    private static let initialCheckDelay: Duration = .seconds(20)
    /// If the app is still alive this long after accepting the relaunch, it did
    /// not happen and the button is offered again.
    private static let installRelaunchTimeout: Duration = .seconds(20)
    private static let upToDateNoticeDuration: Duration = .seconds(8)

    init(
        releaseChannel: String,
        automaticChecksEnabled: Bool,
        defaults: UserDefaults = PickyRuntimeEnvironment.userDefaults,
        engine: (any PickyUpdaterEngine)? = nil
    ) {
        self.releaseChannel = Self.normalizedReleaseChannel(releaseChannel)
        self.automaticChecksEnabled = automaticChecksEnabled
        self.defaults = defaults
        self.dashboardUpdate = PickyDashboardUpdateState(
            dismissedVersion: defaults.string(forKey: Self.dismissedUpdateVersionDefaultsKey)
        )
        super.init()

        applyReleaseChannel()
        userDriver.host = self

        if let engine {
            self.engine = engine
            canCheckForUpdates = true
        } else {
            // Alpha builds are sideloaded testers — they update by reinstalling
            // the DMG, so we never start the Sparkle updater for them.
            guard self.releaseChannel != "alpha" else {
                print("🛠️ PickyUpdater: alpha build — Sparkle updater not started")
                return
            }
            startSparkleUpdater()
        }
        restartScheduledChecks()
    }

    private func startSparkleUpdater() {
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: self
        )
        // Picky schedules its own information-only checks and downloads only
        // after the user presses Update. Clearing both flags also overwrites
        // the values Sparkle persisted for users of earlier Picky versions.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
        } catch {
            print("🛠️ PickyUpdater: failed to start Sparkle updater — \(error)")
            return
        }
        self.updater = updater
        engine = updater

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastUpdateCheckDate)
    }

    var isAvailable: Bool { engine != nil }

    // MARK: - User entry points

    /// "Check for updates" from the menu, Settings, or the Hub sidebar.
    func checkForUpdates() {
        startCheck(intent: .userInformation)
    }

    var updateButtonAction: PickyDashboardUpdateState.UpdateButtonAction? {
        guard isAvailable else { return nil }
        return dashboardUpdate.updateButtonAction(sparkleCanCheckForUpdates: canCheckForUpdates)
    }

    var canRunUpdateButtonAction: Bool { updateButtonAction != nil }

    /// Shared action for the dashboard card, Hub sidebar, Settings, and app menu.
    func runUpdateButtonAction() {
        switch updateButtonAction {
        case .checkForUpdates: startCheck(intent: .userInformation)
        case .startUpdate: startUpdate()
        case .installReadyUpdate: confirmInstallDownloadedUpdate()
        case .openReleaseNotes: openReleaseNotes()
        case nil: break
        }
    }

    /// App menu entry point; `validateMenuItem` keeps it in sync with the Hub buttons.
    @objc func runUpdateButtonAction(_ sender: Any?) {
        runUpdateButtonAction()
    }

    /// Checks the feed again and installs the newest version it returns, so a
    /// release published after the card appeared is the one that gets installed.
    func startUpdate() {
        startCheck(intent: .userInstall)
    }

    /// Asks the host before the relaunch, then installs the downloaded update.
    func confirmInstallDownloadedUpdate() {
        guard let confirm = confirmReadyUpdateInstall else {
            installReadyUpdateNow()
            return
        }
        confirm()
    }

    /// Final step: tell Sparkle to install and relaunch.
    func installReadyUpdateNow() {
        guard dashboardUpdate.beginInstall() else { return }
        if let reply = relaunchReply {
            relaunchReply = nil
            reply(.install)
        } else if let retry = retryTerminatingApplication {
            retry()
        } else {
            dashboardUpdate.installDidNotRelaunch()
            return
        }
        installFallbackTask?.cancel()
        installFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.installRelaunchTimeout)
            guard !Task.isCancelled else { return }
            self?.dashboardUpdate.installDidNotRelaunch()
        }
    }

    func dismissDashboardUpdate() {
        upToDateNoticeTask?.cancel()
        dashboardUpdate.dismiss()
        syncDismissedVersionDefault()
    }

    /// "Later" survives a relaunch, and clearing it has to survive one too:
    /// asking for a check un-hides the card for the version it was hiding.
    private func syncDismissedVersionDefault() {
        if let dismissed = dashboardUpdate.dismissedVersion {
            defaults.set(dismissed, forKey: Self.dismissedUpdateVersionDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.dismissedUpdateVersionDefaultsKey)
        }
    }

    func openReleaseNotes() {
        guard let url = dashboardUpdate.releaseNotesURL else { return }
        NSWorkspace.shared.open(url)
    }

    func updateAutomaticChecksPreference(_ enabled: Bool) {
        guard automaticChecksEnabled != enabled else { return }
        automaticChecksEnabled = enabled
        restartScheduledChecks()
    }

    // MARK: - Checks

    private func startCheck(intent: CheckIntent) {
        guard let engine else { return }
        guard activeIntent == nil, !engine.sessionInProgress else {
            // A check is already running. Remember an install request so it
            // starts as soon as that cycle finishes instead of being dropped.
            if intent == .userInstall, activeIntent != .userInstall {
                pendingUserInstall = true
                dashboardUpdate.checkStarted()
            }
            return
        }
        activeIntent = intent
        switch intent {
        case .scheduled:
            engine.checkForUpdateInformation()
        case .userInformation:
            upToDateNoticeTask?.cancel()
            dashboardUpdate.checkStarted()
            syncDismissedVersionDefault()
            engine.checkForUpdateInformation()
        case .userInstall:
            upToDateNoticeTask?.cancel()
            dashboardUpdate.checkStarted()
            syncDismissedVersionDefault()
            engine.checkForUpdates()
        }
    }

    private func restartScheduledChecks() {
        scheduledCheckTask?.cancel()
        guard automaticChecksEnabled, isAvailable else { return }
        scheduledCheckTask = Task { [weak self] in
            var delay = Self.initialCheckDelay
            while true {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self else { return }
                self.startCheck(intent: .scheduled)
                delay = Self.scheduledCheckInterval
            }
        }
    }

    private func showUpToDateNotice() {
        dashboardUpdate.noUpdateFound(userInitiated: true)
        upToDateNoticeTask?.cancel()
        upToDateNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.upToDateNoticeDuration)
            guard !Task.isCancelled else { return }
            self?.dashboardUpdate.clearUpToDateNotice()
        }
    }

    // MARK: - Channels

    nonisolated static func allowedChannels(forReleaseChannel releaseChannel: String) -> Set<String> {
        switch normalizedReleaseChannel(releaseChannel) {
        case "stable": return ["stable"]
        case "beta": return ["beta"]
        default: return []
        }
    }

    private func applyReleaseChannel() {
        let resolved = Self.allowedChannels(forReleaseChannel: releaseChannel)
        channelLock.lock()
        lockedAllowedChannels = resolved
        channelLock.unlock()
    }

    private nonisolated static func normalizedReleaseChannel(_ releaseChannel: String) -> String {
        releaseChannel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func channelLabel(forReleaseChannel releaseChannel: String) -> String {
        let raw = normalizedReleaseChannel(releaseChannel)
        guard !raw.isEmpty else { return "Unknown" }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

extension PickyUpdaterController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(runUpdateButtonAction(_:)) else { return true }
        return canRunUpdateButtonAction
    }
}

// MARK: - Sparkle updater delegate

extension PickyUpdaterController: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channelLock.lock()
        defer { channelLock.unlock() }
        return lockedAllowedChannels
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Sparkle calls this on the main thread before terminating the app to
        // swap in the new bundle. Hop to MainActor explicitly to satisfy Swift
        // approachable concurrency and run the host's stop hook synchronously.
        MainActor.assumeIsolated {
            willRelaunchApplication?()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let informationOnly = item.isInformationOnlyUpdate
        let candidate = PickyUpdateCandidate(
            version: item.displayVersionString,
            releaseNotesURL: informationOnly ? item.infoURL : (item.fullReleaseNotesURL ?? item.releaseNotesURL),
            isAlreadyDownloaded: false,
            isInformationOnly: informationOnly
        )
        MainActor.assumeIsolated {
            self.informationCheckDidFind(candidate)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated {
            self.informationCheckDidNotFindUpdate()
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.updateCycleDidFinish(error: error)
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            self.dashboardUpdate.updateFailed(version: version)
        }
    }

    /// A check that only read the feed found this version. A full check reports
    /// the same item through the user driver, which owns the download state.
    func informationCheckDidFind(_ candidate: PickyUpdateCandidate) {
        guard activeIntent != .userInstall else { return }
        dashboardUpdate.updateAvailable(
            version: candidate.version,
            releaseNotesURL: candidate.releaseNotesURL,
            isInformationOnly: candidate.isInformationOnly
        )
    }

    func informationCheckDidNotFindUpdate() {
        guard activeIntent != .userInstall else { return }
        if activeIntent == .userInformation {
            showUpToDateNotice()
        } else {
            dashboardUpdate.noUpdateFound(userInitiated: false)
        }
    }

    func updateCycleDidFinish(error: (any Error)?) {
        let intent = activeIntent
        activeIntent = nil
        if intent == .userInformation, dashboardUpdate.phase == .checking {
            // The check ended without a result: treat it as a failed check so
            // the card offers a retry instead of spinning forever.
            if error == nil {
                showUpToDateNotice()
            } else {
                dashboardUpdate.updateFailed(version: nil)
            }
        }
        if pendingUserInstall {
            pendingUserInstall = false
            startCheck(intent: .userInstall)
        }
    }
}

// MARK: - Sparkle user driver host

extension PickyUpdaterController: PickyUpdateUserDriverHost {
    func updateDriverDidStartCheck() {
        dashboardUpdate.checkStarted()
    }

    func updateDriver(didFind candidate: PickyUpdateCandidate, reply: @escaping (PickyUpdateReply) -> Void) {
        guard activeIntent == .userInstall, !candidate.isInformationOnly else {
            // Sparkle presented an update Picky did not ask to install (an
            // informational item, or an archive an older Picky downloaded in
            // the background). Keep it, and show it as available instead.
            dashboardUpdate.updateSessionEnded()
            dashboardUpdate.updateAvailable(
                version: candidate.version,
                releaseNotesURL: candidate.releaseNotesURL,
                isInformationOnly: candidate.isInformationOnly
            )
            reply(.dismiss)
            return
        }
        dashboardUpdate.downloadStarted(version: candidate.version, releaseNotesURL: candidate.releaseNotesURL)
        syncDismissedVersionDefault()
        reply(.install)
    }

    func updateDriverDidNotFindUpdate() {
        showUpToDateNotice()
    }

    func updateDriver(didFail error: any Error) {
        print("🛠️ PickyUpdater: update failed — \(error)")
        dashboardUpdate.updateFailed(version: nil)
    }

    func updateDriverDidStartDownload() {
        dashboardUpdate.downloadProgress(nil)
    }

    func updateDriver(didChangeDownloadProgress fraction: Double?) {
        dashboardUpdate.downloadProgress(fraction)
    }

    func updateDriverIsReadyToRelaunch(reply: @escaping (PickyUpdateReply) -> Void) {
        relaunchReply = reply
        dashboardUpdate.readyToRelaunch(version: nil)
        confirmInstallDownloadedUpdate()
    }

    func updateDriverDidStartInstalling(retryTerminatingApplication: @escaping () -> Void) {
        self.retryTerminatingApplication = retryTerminatingApplication
    }

    func updateDriverDidEndSession() {
        relaunchReply = nil
        retryTerminatingApplication = nil
        installFallbackTask?.cancel()
        dashboardUpdate.updateSessionEnded()
    }
}
