//
//  PickyUpdateUserDriver.swift
//  Picky
//
//  Sparkle user driver for Picky's Hub-owned update flow. Picky never shows
//  Sparkle's own windows: scheduled checks only read version information, and
//  pressing Update in the Hub starts a fresh appcast check whose newest item
//  is downloaded and installed here. See docs/auto-update.md.
//

import Foundation
import Sparkle

/// Picky's answer when Sparkle presents an update or asks to relaunch.
enum PickyUpdateReply: Equatable {
    case install
    case dismiss
}

/// A Sparkle appcast item reduced to what the Hub renders. Keeping the
/// controller and the card on this type means only this file maps Sparkle
/// objects into Picky.
struct PickyUpdateCandidate: Equatable {
    var version: String
    var releaseNotesURL: URL?
    /// Sparkle already holds this archive: an update an older Picky downloaded
    /// in the background, or an install that was interrupted. Installing it
    /// reuses the download instead of fetching it again.
    var isAlreadyDownloaded: Bool
    /// Informational items must never be downloaded; they only link out.
    var isInformationOnly: Bool
}

/// What `PickyUpdaterController` implements to receive driver events. Sparkle
/// types stop here so the controller and its tests stay Sparkle-free.
@MainActor
protocol PickyUpdateUserDriverHost: AnyObject {
    func updateDriverDidStartCheck()
    func updateDriver(didFind candidate: PickyUpdateCandidate, reply: @escaping (PickyUpdateReply) -> Void)
    func updateDriverDidNotFindUpdate()
    func updateDriver(didFail error: any Error)
    func updateDriverDidStartDownload()
    func updateDriver(didChangeDownloadProgress fraction: Double?)
    func updateDriverIsReadyToRelaunch(reply: @escaping (PickyUpdateReply) -> Void)
    func updateDriverDidStartInstalling(retryTerminatingApplication: @escaping () -> Void)
    func updateDriverDidEndSession()
}

@MainActor
final class PickyUpdateUserDriver: NSObject, SPUUserDriver {
    weak var host: (any PickyUpdateUserDriverHost)?

    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    // MARK: - Check

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // `SUEnableAutomaticChecks` in Info.plist means Sparkle never asks, and
        // Picky schedules its own information-only checks. Answer right away so
        // a future Sparkle change can't leave the updater waiting on a prompt
        // Picky does not show.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        host?.updateDriverDidStartCheck()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        expectedContentLength = 0
        receivedContentLength = 0
        let informationOnly = appcastItem.isInformationOnlyUpdate
        let candidate = PickyUpdateCandidate(
            version: appcastItem.displayVersionString,
            releaseNotesURL: informationOnly
                ? appcastItem.infoURL
                : (appcastItem.fullReleaseNotesURL ?? appcastItem.releaseNotesURL),
            isAlreadyDownloaded: state.stage != .notDownloaded,
            isInformationOnly: informationOnly
        )
        guard let host else {
            reply(.dismiss)
            return
        }
        host.updateDriver(didFind: candidate) { choice in
            reply(choice == .install ? .install : .dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release notes open in the browser from the Hub card instead.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        host?.updateDriverDidNotFindUpdate()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        host?.updateDriver(didFail: error)
        acknowledgement()
    }

    // MARK: - Download and install

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedContentLength = 0
        receivedContentLength = 0
        host?.updateDriverDidStartDownload()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        // Sparkle may report this more than once for the same download.
        self.expectedContentLength = expectedContentLength
        receivedContentLength = 0
        host?.updateDriver(didChangeDownloadProgress: nil)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        guard expectedContentLength > 0 else {
            host?.updateDriver(didChangeDownloadProgress: nil)
            return
        }
        let fraction = Double(receivedContentLength) / Double(expectedContentLength)
        host?.updateDriver(didChangeDownloadProgress: min(max(fraction, 0), 1))
    }

    func showDownloadDidStartExtractingUpdate() {
        host?.updateDriver(didChangeDownloadProgress: nil)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let host else {
            reply(.dismiss)
            return
        }
        host.updateDriverIsReadyToRelaunch { choice in
            reply(choice == .install ? .install : .dismiss)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        host?.updateDriverDidStartInstalling(retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        host?.updateDriverDidEndSession()
    }
}

/// The slice of `SPUUpdater` the controller drives. Tests substitute a fake so
/// the check/download/install flow runs without a real Sparkle session.
@MainActor
protocol PickyUpdaterEngine: AnyObject {
    var sessionInProgress: Bool { get }
    /// Reads the appcast without offering or downloading anything.
    func checkForUpdateInformation()
    /// Full check: found updates are presented through the user driver.
    func checkForUpdates()
}

extension SPUUpdater: PickyUpdaterEngine {}
