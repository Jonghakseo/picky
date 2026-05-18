//
//  PickyUpdaterController.swift
//  Picky
//
//  Sparkle 2 controller. Wraps SPUStandardUpdaterController so the rest of
//  Picky can keep using PickySettings + AppBundleConfiguration without
//  importing Sparkle directly. See docs/auto-update.md for the design.
//

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

    init(releaseChannel: String, automaticChecksEnabled: Bool) {
        self.releaseChannel = Self.normalizedReleaseChannel(releaseChannel)
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
            userDriverDelegate: nil
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
}
