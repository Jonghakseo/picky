//
//  PickyDashboardUpdateStateTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyDashboardUpdateStateTests {
    @Test func downloadedUpdateKeepsOfferingInstallUntilRestart() {
        var state = PickyDashboardUpdateState()
        #expect(state.card == nil)

        state.downloadStarted(version: "0.9.0", releaseNotesURL: URL(string: "https://example.com/notes"))
        #expect(state.card == .downloading(progress: nil))
        state.downloadProgress(0.5)
        #expect(state.card == .downloading(progress: 0.5))

        state.readyToRelaunch(version: nil)
        #expect(state.card == .ready)
        #expect(state.version == "0.9.0")

        let firstClick = state.beginInstall()
        #expect(firstClick)
        #expect(state.card == .installing)
        // A second click while restarting must not run the installer again.
        let secondClick = state.beginInstall()
        #expect(!secondClick)

        state.installDidNotRelaunch()
        #expect(state.card == .ready)
    }

    @Test func updateButtonInstallsDownloadedUpdateWhileSparkleBlocksChecks() {
        var state = PickyDashboardUpdateState()
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: true) == .checkForUpdates)
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: false) == nil)

        state.updateAvailable(version: "0.9.0", releaseNotesURL: nil)
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: true) == .startUpdate)

        // Sparkle keeps canCheckForUpdates false once it holds a downloaded
        // update; the install button must stay usable, even after "Later".
        state.downloadStarted(version: "0.9.0", releaseNotesURL: nil)
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: false) == nil)
        state.readyToRelaunch(version: nil)
        state.dismiss()
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: false) == .installReadyUpdate)

        _ = state.beginInstall()
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: false) == nil)
        state.installDidNotRelaunch()
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: false) == .installReadyUpdate)
    }

    @Test func informationOnlyUpdateOpensItsPageInsteadOfDownloading() {
        var state = PickyDashboardUpdateState()
        state.updateAvailable(
            version: "1.0.0",
            releaseNotesURL: URL(string: "https://example.com/info"),
            isInformationOnly: true
        )
        #expect(state.card == .available)
        #expect(state.updateButtonAction(sparkleCanCheckForUpdates: true) == .openReleaseNotes)
    }

    @Test func laterHidesOnlyThatVersion() {
        var state = PickyDashboardUpdateState()
        state.updateAvailable(version: "0.9.0", releaseNotesURL: nil)
        state.dismiss()
        #expect(state.card == nil)

        var relaunched = PickyDashboardUpdateState(dismissedVersion: state.dismissedVersion)
        relaunched.updateAvailable(version: "0.9.0", releaseNotesURL: nil)
        #expect(relaunched.card == nil)
        relaunched.updateAvailable(version: "0.9.1", releaseNotesURL: nil)
        #expect(relaunched.card == .available)
    }

    @Test func askingForACheckUnhidesTheVersionLaterHid() {
        var state = PickyDashboardUpdateState(dismissedVersion: "0.9.0")
        state.checkStarted()
        #expect(state.card == .checking)
        state.updateAvailable(version: "0.9.0", releaseNotesURL: nil)
        #expect(state.card == .available)
        #expect(state.dismissedVersion == nil)
    }

    @Test func onlyRequestedChecksReportThatPickyIsUpToDate() {
        var scheduled = PickyDashboardUpdateState()
        scheduled.updateAvailable(version: "0.9.0", releaseNotesURL: nil)
        scheduled.noUpdateFound(userInitiated: false)
        #expect(scheduled.card == nil)

        var requested = PickyDashboardUpdateState()
        requested.checkStarted()
        requested.noUpdateFound(userInitiated: true)
        #expect(requested.card == .upToDate)
        requested.clearUpToDateNotice()
        #expect(requested.card == nil)
    }

    @Test func checkResultsNeverReplaceAnUpdateBeingInstalled() {
        var state = PickyDashboardUpdateState()
        state.downloadStarted(version: "0.9.1", releaseNotesURL: nil)
        state.updateAvailable(version: "0.9.0", releaseNotesURL: nil)
        state.noUpdateFound(userInitiated: true)
        state.checkStarted()
        #expect(state.card == .downloading(progress: nil))
        #expect(state.version == "0.9.1")
    }

    @Test func abortedSessionFallsBackToTheAvailableNotice() {
        var state = PickyDashboardUpdateState()
        state.downloadStarted(version: "0.9.1", releaseNotesURL: nil)
        state.updateSessionEnded()
        #expect(state.card == .available)
        #expect(state.version == "0.9.1")

        var empty = PickyDashboardUpdateState()
        empty.checkStarted()
        empty.updateSessionEnded()
        #expect(empty.card == nil)
    }

    @Test func restartConfirmationCountsOnlyPicklesMidResponse() {
        let statuses: [PickySessionStatus] = [.running, .queued, .waiting_for_input, .blocked, .completed, .failed, .cancelled]
        #expect(PickyUpdateRestartPolicy.interruptedPickleCount(statuses: statuses) == 2)
        #expect(PickyUpdateRestartPolicy.interruptedPickleCount(statuses: [.completed]) == 0)
    }
}

/// Stands in for `SPUUpdater` so the check/download/install flow runs without
/// starting Sparkle. It mirrors Sparkle's session rule: a check occupies the
/// updater until the cycle finishes.
@MainActor
private final class FakeUpdaterEngine: PickyUpdaterEngine {
    private(set) var sessionInProgress = false
    private(set) var informationCheckCount = 0
    private(set) var fullCheckCount = 0

    func checkForUpdateInformation() {
        informationCheckCount += 1
        sessionInProgress = true
    }

    func checkForUpdates() {
        fullCheckCount += 1
        sessionInProgress = true
    }

    func finishSession() {
        sessionInProgress = false
    }
}

@MainActor
struct PickyUpdaterControllerFlowTests {
    private func makeController(
        engine: FakeUpdaterEngine,
        defaults: UserDefaults
    ) -> PickyUpdaterController {
        PickyUpdaterController(
            releaseChannel: "stable",
            automaticChecksEnabled: false,
            defaults: defaults,
            engine: engine
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PickyUpdaterControllerFlowTests-\(UUID().uuidString)")!
    }

    /// The contract that motivated splitting information checks from installs:
    /// the version Picky advertises can go stale, so pressing Update must
    /// install whatever the fresh check returns, not the advertised build.
    @Test func updateInstallsTheVersionTheFreshCheckReturns() {
        let engine = FakeUpdaterEngine()
        let controller = makeController(engine: engine, defaults: makeDefaults())

        // A check that only reads the feed advertises 0.9.1 and downloads nothing.
        controller.checkForUpdates()
        controller.informationCheckDidFind(
            PickyUpdateCandidate(
                version: "0.9.1",
                releaseNotesURL: nil,
                isAlreadyDownloaded: false,
                isInformationOnly: false
            )
        )
        engine.finishSession()
        controller.updateCycleDidFinish(error: nil)
        #expect(controller.dashboardUpdate.card == .available)
        #expect(controller.dashboardUpdate.version == "0.9.1")
        #expect(engine.informationCheckCount == 1)
        #expect(engine.fullCheckCount == 0)

        // 0.9.2 ships before the user presses Update.
        #expect(controller.updateButtonAction == .startUpdate)
        controller.runUpdateButtonAction()
        #expect(engine.fullCheckCount == 1)

        var reply: PickyUpdateReply?
        controller.updateDriver(
            didFind: PickyUpdateCandidate(
                version: "0.9.2",
                releaseNotesURL: nil,
                isAlreadyDownloaded: false,
                isInformationOnly: false
            ),
            reply: { reply = $0 }
        )
        #expect(reply == .install)
        #expect(controller.dashboardUpdate.version == "0.9.2")
        #expect(controller.dashboardUpdate.card == .downloading(progress: nil))
    }

    @Test func repeatedClicksRunOneUpdateSession() {
        let engine = FakeUpdaterEngine()
        let controller = makeController(engine: engine, defaults: makeDefaults())
        controller.informationCheckDidFind(
            PickyUpdateCandidate(version: "0.9.1", releaseNotesURL: nil, isAlreadyDownloaded: false, isInformationOnly: false)
        )

        controller.runUpdateButtonAction()
        controller.runUpdateButtonAction()
        #expect(engine.fullCheckCount == 1)

        controller.updateDriver(
            didFind: PickyUpdateCandidate(version: "0.9.1", releaseNotesURL: nil, isAlreadyDownloaded: false, isInformationOnly: false),
            reply: { _ in }
        )
        #expect(controller.canRunUpdateButtonAction == false)
    }

    @Test func clickDuringACheckStartsTheUpdateWhenThatCheckEnds() {
        let engine = FakeUpdaterEngine()
        let controller = makeController(engine: engine, defaults: makeDefaults())

        controller.checkForUpdates()
        #expect(engine.informationCheckCount == 1)

        // Pressing Update while the feed is still being read must not be lost.
        controller.startUpdate()
        #expect(engine.fullCheckCount == 0)
        #expect(controller.dashboardUpdate.card == .checking)

        engine.finishSession()
        controller.updateCycleDidFinish(error: nil)
        #expect(engine.fullCheckCount == 1)
    }

    @Test func relaunchWaitsForTheHostConfirmationAndStaysInstallable() {
        let engine = FakeUpdaterEngine()
        let controller = makeController(engine: engine, defaults: makeDefaults())
        var confirmations = 0
        controller.confirmReadyUpdateInstall = { confirmations += 1 }

        controller.startUpdate()
        controller.updateDriver(
            didFind: PickyUpdateCandidate(version: "0.9.2", releaseNotesURL: nil, isAlreadyDownloaded: false, isInformationOnly: false),
            reply: { _ in }
        )

        var relaunchReplies: [PickyUpdateReply] = []
        controller.updateDriverIsReadyToRelaunch { relaunchReplies.append($0) }
        // Confirmation is asked for, and nothing is installed until it returns.
        #expect(confirmations == 1)
        #expect(relaunchReplies.isEmpty)
        #expect(controller.dashboardUpdate.card == .ready)
        #expect(controller.updateButtonAction == .installReadyUpdate)

        // The user cancelled, then accepted from the card later.
        controller.installReadyUpdateNow()
        #expect(relaunchReplies == [.install])
        #expect(controller.dashboardUpdate.card == .installing)
        controller.installReadyUpdateNow()
        #expect(relaunchReplies == [.install])
    }

    @Test func updatesSparkleAlreadyHoldsAreShownInsteadOfInstalledSilently() {
        let engine = FakeUpdaterEngine()
        let controller = makeController(engine: engine, defaults: makeDefaults())

        // An archive an older Picky downloaded in the background: Sparkle may
        // present it without the user asking, so it must not install itself.
        var reply: PickyUpdateReply?
        controller.updateDriver(
            didFind: PickyUpdateCandidate(version: "0.9.0", releaseNotesURL: nil, isAlreadyDownloaded: true, isInformationOnly: false),
            reply: { reply = $0 }
        )
        #expect(reply == .dismiss)
        #expect(controller.dashboardUpdate.card == .available)
        #expect(controller.dashboardUpdate.version == "0.9.0")
    }

    @Test func alphaBuildsDoNotStartTheUpdater() {
        let controller = PickyUpdaterController(
            releaseChannel: "alpha",
            automaticChecksEnabled: true,
            defaults: makeDefaults()
        )
        #expect(controller.isAvailable == false)
        #expect(controller.updateButtonAction == nil)
    }
}
