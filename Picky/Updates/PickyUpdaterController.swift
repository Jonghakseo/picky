//
//  PickyUpdaterController.swift
//  Picky
//
//  Sparkle 2 controller. Wraps SPUStandardUpdaterController so the rest of
//  Picky can keep using PickySettings + AppBundleConfiguration without
//  importing Sparkle directly. See docs/auto-update.md for the design.
//

import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
final class PickyUpdaterController: NSObject, ObservableObject {
    /// Mirrors `SPUUpdater.canCheckForUpdates` so SwiftUI can disable the
    /// "Check for Updates…" button while a check is already in flight.
    @Published private(set) var canCheckForUpdates: Bool = false
    /// Reflects the last appcast fetch the SPUUpdater performed.
    @Published private(set) var lastUpdateCheckDate: Date?
    /// Drives the Hub dashboard update card.
    @Published private(set) var dashboardUpdate: PickyDashboardUpdateState
    /// Mirrors `SPUUpdater.automaticallyDownloadsUpdates`. Sparkle owns the
    /// persisted value (`SUAutomaticallyUpdate`, default YES in Info.plist).
    @Published private(set) var automaticallyDownloadsUpdates: Bool = false
    /// False while automatic checks are off; Sparkle then ignores auto-download.
    @Published private(set) var allowsAutomaticUpdates: Bool = false
    // Sparkle reads `allowedChannels(for:)` from non-main threads, so the
    // currently allowed channel set is held behind a lock and updated from
    // the main actor whenever the user flips the preference. The pair is
    // exposed as nonisolated so the lock itself can be acquired off-main —
    // the NSLock is what makes concurrent access safe.
    private nonisolated let channelLock = NSLock()
    private nonisolated(unsafe) var lockedAllowedChannels: Set<String> = []

    private let releaseChannel: String
    private(set) var standardController: SPUStandardUpdaterController?

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

    private var cancellables: Set<AnyCancellable> = []
    private var immediateInstallHandler: (() -> Void)?
    private var installFallbackTask: Task<Void, Never>?
    private let defaults: UserDefaults

    static let dismissedUpdateVersionDefaultsKey = "PickyDashboardDismissedUpdateVersion"
    /// If the app is still alive this long after the install handler ran, the
    /// relaunch did not happen and the button is offered again.
    private static let installRelaunchTimeout: Duration = .seconds(20)

    init(
        releaseChannel: String,
        automaticChecksEnabled: Bool,
        defaults: UserDefaults = PickyRuntimeEnvironment.userDefaults
    ) {
        self.releaseChannel = Self.normalizedReleaseChannel(releaseChannel)
        self.defaults = defaults
        self.dashboardUpdate = PickyDashboardUpdateState(
            dismissedVersion: defaults.string(forKey: Self.dismissedUpdateVersionDefaultsKey)
        )
        super.init()

        applyReleaseChannel()

        // Alpha builds are sideloaded testers — they update by reinstalling
        // the DMG, so we never start the Sparkle updater for them.
        guard self.releaseChannel != "alpha" else {
            print("🛠️ PickyUpdater: alpha build — Sparkle updater not started")
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        controller.updater.automaticallyChecksForUpdates = automaticChecksEnabled
        controller.startUpdater()
        self.standardController = controller

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastUpdateCheckDate)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$automaticallyDownloadsUpdates)
        controller.updater.publisher(for: \.allowsAutomaticUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$allowsAutomaticUpdates)
    }

    var isAvailable: Bool { standardController != nil }

    func checkForUpdates() {
        guard let controller = standardController else {
            print("🛠️ PickyUpdater: checkForUpdates ignored on alpha build")
            return
        }
        controller.checkForUpdates(nil)
    }

    func updateAutomaticChecksPreference(_ enabled: Bool) {
        standardController?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        standardController?.updater.automaticallyDownloadsUpdates = enabled
    }

    /// One-click path from the dashboard card: install the already downloaded
    /// update and relaunch. `willRelaunchApplication` stops agentd first.
    func installReadyUpdateNow() {
        guard let handler = immediateInstallHandler, dashboardUpdate.beginInstall() else { return }
        handler()
        installFallbackTask?.cancel()
        installFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.installRelaunchTimeout)
            guard !Task.isCancelled else { return }
            self?.dashboardUpdate.installDidNotRelaunch()
        }
    }

    /// Fallback and retry path: bring Sparkle's own update window forward.
    func openUpdateWindow() {
        dashboardUpdate.handedOffToUpdateWindow()
        checkForUpdates()
    }

    func dismissDashboardUpdate() {
        dashboardUpdate.dismiss()
        defaults.set(dashboardUpdate.dismissedVersion, forKey: Self.dismissedUpdateVersionDefaultsKey)
    }

    func openReleaseNotes() {
        guard let url = dashboardUpdate.releaseNotesURL else { return }
        NSWorkspace.shared.open(url)
    }

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

    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Returning YES keeps Sparkle from nagging later; it still installs on
        // quit, and the dashboard card offers the immediate path.
        let version = item.displayVersionString
        let notes = item.fullReleaseNotesURL ?? item.releaseNotesURL
        MainActor.assumeIsolated {
            self.immediateInstallHandler = immediateInstallHandler
            self.dashboardUpdate.updateReadyToInstall(version: version, releaseNotesURL: notes)
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            self.dashboardUpdate.downloadFailed(version: version)
        }
    }
}

extension PickyUpdaterController: SPUStandardUserDriverDelegate {
    // Picky is an LSUIElement app, so Sparkle's scheduled alert often lands
    // behind other windows. Let the dashboard card act as the gentle reminder.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Right after launch or after the Mac was idle, Sparkle's alert is
        // visible and fine. Otherwise the dashboard card takes over.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        let notes = update.fullReleaseNotesURL ?? update.releaseNotesURL
        MainActor.assumeIsolated {
            self.dashboardUpdate.updateNeedsWindow(version: version, releaseNotesURL: notes)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            self.dashboardUpdate.handedOffToUpdateWindow()
        }
    }
}
