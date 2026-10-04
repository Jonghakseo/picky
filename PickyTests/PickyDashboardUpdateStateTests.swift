//
//  PickyDashboardUpdateStateTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyDashboardUpdateStateTests {
    @Test func downloadedUpdateShowsOneClickCardUntilRestart() {
        var state = PickyDashboardUpdateState()
        #expect(state.card == nil)

        state.updateReadyToInstall(version: "0.9.0", releaseNotesURL: URL(string: "https://example.com/notes"))
        #expect(state.card == .ready)
        let firstClick = state.beginInstall()
        #expect(firstClick)
        #expect(state.card == .installing)
        // A second click while restarting must not run the installer again.
        let secondClick = state.beginInstall()
        #expect(!secondClick)

        state.installDidNotRelaunch()
        #expect(state.card == .ready)
    }

    @Test func updateButtonInstallsReadyUpdateWhileSparkleBlocksChecks() {
        var state = PickyDashboardUpdateState()
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: true) == .checkForUpdates)
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: false) == nil)

        // Sparkle keeps canCheckForUpdates false until quit once the update is
        // downloaded; the button must stay usable, even after "Later".
        state.updateReadyToInstall(version: "0.9.0", releaseNotesURL: nil)
        state.dismiss()
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: false) == .installReadyUpdate)

        _ = state.beginInstall()
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: false) == nil)
        state.installDidNotRelaunch()
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: false) == .installReadyUpdate)
    }

    @Test func laterHidesOnlyThatVersion() {
        var state = PickyDashboardUpdateState()
        state.updateReadyToInstall(version: "0.9.0", releaseNotesURL: nil)
        state.dismiss()
        #expect(state.card == nil)

        var relaunched = PickyDashboardUpdateState(dismissedVersion: state.dismissedVersion)
        relaunched.updateReadyToInstall(version: "0.9.0", releaseNotesURL: nil)
        #expect(relaunched.card == nil)
        relaunched.updateReadyToInstall(version: "0.9.1", releaseNotesURL: nil)
        #expect(relaunched.card == .ready)
    }

    @Test func downloadedUpdateWinsOverWindowAndFailureNotices() {
        var state = PickyDashboardUpdateState()
        state.updateReadyToInstall(version: "0.9.0", releaseNotesURL: nil)
        state.updateNeedsWindow(version: "0.9.0", releaseNotesURL: nil)
        state.downloadFailed(version: "0.9.1")
        #expect(state.card == .ready)
        #expect(state.version == "0.9.0")
    }

    @Test func windowAndFailureNoticesClearWhenSparkleWindowTakesOver() {
        var state = PickyDashboardUpdateState()
        state.updateNeedsWindow(version: "0.9.0", releaseNotesURL: nil)
        #expect(state.card == .needsUpdateWindow)
        state.handedOffToUpdateWindow()
        #expect(state.card == nil)

        state.downloadFailed(version: "0.9.0")
        #expect(state.card == .downloadFailed)
        state.handedOffToUpdateWindow()
        #expect(state.card == nil)
    }

    @Test func restartConfirmationCountsOnlyPicklesMidResponse() {
        let statuses: [PickySessionStatus] = [.running, .queued, .waiting_for_input, .blocked, .completed, .failed, .cancelled]
        #expect(PickyUpdateRestartPolicy.interruptedPickleCount(statuses: statuses) == 2)
        #expect(PickyUpdateRestartPolicy.interruptedPickleCount(statuses: [.completed]) == 0)
    }
}
