//
//  PickyHubQuickStartLauncherTests.swift
//  PickyTests
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Picky

private final class QuickStartClient: PickyAgentClient {
    enum StrictResponse {
        case acknowledged
        case rejected(code: String, message: String)
        case timedOut
        case delayed
    }

    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    private(set) var sentCommands: [PickyCommandEnvelope] = []
    var strictResponse: StrictResponse = .acknowledged

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "unused", message: "unused")
    }

    func send(_ command: PickyCommandEnvelope) async throws {
        sentCommands.append(command)
    }

    func sendAwaitingError(
        _ command: PickyCommandEnvelope,
        timeout: TimeInterval,
        requireAcknowledgement: Bool
    ) async throws -> PickyErrorEvent? {
        try await send(command)
        guard requireAcknowledgement else { return nil }
        switch strictResponse {
        case .acknowledged:
            return nil
        case .rejected(let code, let message):
            return PickyErrorEvent(code: code, message: message, commandId: command.id)
        case .timedOut:
            throw PickyAgentClientRouterError.commandAcknowledgementTimedOut(commandId: command.id)
        case .delayed:
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return nil
        }
    }

    func disconnect() { continuation.yield(.disconnected) }
}

private final class SendOnlyQuickStartClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    private(set) var sentCommands: [PickyCommandEnvelope] = []

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "unused", message: "unused")
    }

    func send(_ command: PickyCommandEnvelope) async throws {
        sentCommands.append(command)
    }

    func disconnect() { continuation.yield(.disconnected) }
}

@MainActor
private final class QuickStartChildSpawner: PickyManualPickleChildSpawning {
    struct Call: Equatable {
        let sessionID: String
        let cwd: String
    }

    let childClient = QuickStartClient()
    private(set) var calls: [Call] = []

    func spawnManualPickleChildClient(sessionId: String, cwd: String) async throws -> any PickyAgentClient {
        calls.append(Call(sessionID: sessionId, cwd: cwd))
        return childClient
    }
}

@MainActor
private final class QuickStartSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
    var screenContextTargetSticky = false

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sticky
    }
}

@MainActor
private final class QuickStartArchiveStore: PickySessionArchiveStoring {
    var archivedSessionIDs = Set<String>()
    var manuallyArchivedSessionIDs = Set<String>()
}

@MainActor
private final class QuickStartManualOrderStore: PickySessionManualOrderStoring {
    var manualOrder: [String] = []
}

@MainActor
struct PickyHubQuickStartLauncherTests {
    @Test func firstInstructionInjectsTheSelectedReplyLanguage() {
        let korean = PickyHubQuickStartLauncher.firstInstruction(
            for: .landingPage,
            locale: Locale(identifier: "ko_KR")
        )
        let english = PickyHubQuickStartLauncher.firstInstruction(
            for: .landingPage,
            locale: Locale(identifier: "en_US")
        )

        #expect(korean.contains("Reply language: Korean"))
        #expect(english.contains("Reply language: English"))
        #expect(korean.contains("Start the interview now with the first question."))
    }

    @Test func missingBundledGuideFallsBackToAUsableInstruction() {
        let workflow = PickyHubQuickStartWorkflow(
            id: "missing",
            titleKey: "hub.quickStart.workflow.missing.title",
            descriptionKey: "hub.quickStart.workflow.missing.description",
            systemImage: "questionmark",
            guideResourceName: "missing-quick-start-guide"
        )

        let guide = workflow.loadGuide(bundle: .main)

        #expect(guide.hasPrefix("# "))
        #expect(!guide.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func fixedWorkflowSetProvidesTheFourSupportedStartingPoints() {
        #expect(PickyHubQuickStartWorkflow.all.map(\.id) == ["landing", "native", "guide", "files"])
        #expect(PickyHubQuickStartWorkflow.workflow(id: "unknown") == nil)
    }

    @Test func sendOnlyClientCannotFalselyConfirmAStrictFollowUp() async throws {
        let client = SendOnlyQuickStartClient()
        let sessions = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: QuickStartSelectionStore(),
            archiveStore: QuickStartArchiveStore(),
            manualOrderStore: QuickStartManualOrderStore(),
            sessionProjectionStorage: PickyRegistrySessionProjectionStorage()
        )
        project("quick-1", into: sessions)

        await #expect(throws: PickyStrictAcknowledgementError.unavailable) {
            try await sessions.followUp(
                text: "Start the quick start",
                sessionID: "quick-1",
                requireAcknowledgement: true
            )
        }

        #expect(client.sentCommands.isEmpty)
        #expect(sessions.sessions.first?.lastRequestText == nil)
    }

    @Test func acknowledgedKickoffPersistsAcceptanceAndUpdatesTheProjectedSession() async throws {
        let fixture = makeFixture(sessionIDs: ["quick-1"])
        project("quick-1", into: fixture.sessions)

        await fixture.launcher.start(.landingPage, cwd: "  /tmp/quick-start  ")

        #expect(fixture.rootClient.sentCommands.count == 1)
        #expect(fixture.rootClient.sentCommands.first?.type == .followUp)
        #expect(fixture.rootClient.sentCommands.first?.sessionId == "quick-1")
        #expect(fixture.childSpawner.calls == [.init(sessionID: "quick-1", cwd: "/tmp/quick-start")])
        #expect(fixture.launcher.lastRecord?.deliveryState == .accepted)
        #expect(fixture.sessions.sessions.first?.lastRequestText?.contains("Start the interview now") == true)
        #expect(fixture.launcher.phase == .started(workflowID: "landing", sessionID: "quick-1"))
    }

    @Test func delayedProjectionWaitsBeforeSendingTheStrictKickoff() async throws {
        let fixture = makeFixture(sessionIDs: ["quick-1"])
        let launch = Task { @MainActor in
            await fixture.launcher.start(.landingPage, cwd: "/tmp/quick-start")
        }

        try await waitUntil { fixture.childSpawner.calls.count == 1 }
        #expect(fixture.rootClient.sentCommands.isEmpty)

        project("quick-1", into: fixture.sessions)
        await launch.value

        #expect(fixture.rootClient.sentCommands.count == 1)
        #expect(fixture.launcher.lastRecord?.deliveryState == .accepted)
    }

    @Test func correlatedRejectionRetainsTheSessionWithoutBlindlyResendingAfterPartialFailure() async throws {
        let fixture = makeFixture(sessionIDs: ["quick-1"])
        fixture.rootClient.strictResponse = .rejected(
            code: "unknown_session",
            message: "The Pickle rejected the instruction"
        )
        project("quick-1", into: fixture.sessions)

        await fixture.launcher.start(.landingPage, cwd: "/tmp/chosen-folder")

        #expect(fixture.launcher.lastRecord?.deliveryState == .rejected)
        #expect(fixture.sessions.sessions.first?.lastRequestText == nil)
        #expect(
            fixture.launcher.phase == .failed(
                workflowID: "landing",
                message: "The Pickle rejected the instruction"
            )
        )

        fixture.rootClient.strictResponse = .acknowledged
        await fixture.launcher.retry()

        #expect(fixture.childSpawner.calls == [.init(sessionID: "quick-1", cwd: "/tmp/chosen-folder")])
        #expect(fixture.rootClient.sentCommands.map(\.sessionId) == ["quick-1"])
        #expect(fixture.launcher.lastRecord?.cwd == "/tmp/chosen-folder")
        #expect(fixture.launcher.lastRecord?.deliveryState == .rejected)
    }

    @Test func acknowledgementTimeoutLeavesOnePendingSessionAndRetryDoesNotResendItsInstruction() async throws {
        let fixture = makeFixture(sessionIDs: ["quick-1"])
        fixture.rootClient.strictResponse = .timedOut
        project("quick-1", into: fixture.sessions)

        await fixture.launcher.start(.landingPage, cwd: "/tmp/quick-start")

        #expect(fixture.launcher.lastRecord?.deliveryState == .deliveryUnknown)
        #expect(fixture.launcher.phase != .started(workflowID: "landing", sessionID: "quick-1"))
        #expect(fixture.rootClient.sentCommands.count == 1)

        fixture.rootClient.strictResponse = .acknowledged
        await fixture.launcher.retry()

        #expect(fixture.childSpawner.calls.count == 1)
        #expect(fixture.rootClient.sentCommands.count == 1)
        #expect(fixture.launcher.lastRecord?.sessionID == "quick-1")
    }

    @Test func cancelledEarlierLaunchCannotReplaceALaterAcceptedLaunchPhase() async throws {
        let fixture = makeFixture(sessionIDs: ["quick-1", "quick-2"])
        project("quick-1", into: fixture.sessions)
        project("quick-2", into: fixture.sessions)
        fixture.rootClient.strictResponse = .delayed

        let first = Task { @MainActor in
            await fixture.launcher.start(.landingPage, cwd: "/tmp/first")
        }
        try await waitUntil { fixture.rootClient.sentCommands.count == 1 }

        fixture.launcher.acknowledge()
        #expect(fixture.launcher.phase == .starting(workflowID: "landing"))
        #expect(fixture.launcher.lastRecord?.deliveryState == .deliveryUnknown)
        first.cancel()
        await first.value
        fixture.launcher.acknowledge()
        fixture.rootClient.strictResponse = .acknowledged
        await fixture.launcher.start(.nativeApp, cwd: "/tmp/second")
        await first.value

        #expect(fixture.launcher.phase == .started(workflowID: "native", sessionID: "quick-2"))
        #expect(fixture.launcher.lastRecord?.sessionID == "quick-2")
        #expect(fixture.rootClient.sentCommands.map(\.sessionId) == ["quick-1", "quick-2"])
    }

    @Test func selectionAloneDoesNotRestoreAHiddenHUD() {
        let fixture = makeFixture(sessionIDs: [])
        let hud = QuickStartHUDHarness(sessions: fixture.sessions)
        defer { try? FileManager.default.removeItem(at: hud.root) }
        project("quick-1", into: fixture.sessions)
        hud.hide()

        fixture.sessions.requestOpenSession(sessionID: "quick-1", targetDisplayID: nil)

        #expect(fixture.sessions.openSessionRequest?.sessionID == "quick-1")
        #expect(!hud.visibilityStore.isVisible(for: 777))
        #expect(!hud.target.isVisible)
    }

    @Test(arguments: ["rejected", "timedOut"])
    func unacceptedKickoffKeepsHUDHiddenUntilExplicitRecovery(response: String) async {
        var presentSession: (String) -> Void = { _ in }
        let fixture = makeFixture(sessionIDs: ["quick-1"], presentSessionInHUD: { presentSession($0) })
        let hud = QuickStartHUDHarness(sessions: fixture.sessions)
        defer { try? FileManager.default.removeItem(at: hud.root) }
        presentSession = { sessionID in
            hud.manager.focusSession(id: sessionID, targetDisplayID: 777, persistVisibility: false)
        }
        project("quick-1", into: fixture.sessions)
        fixture.rootClient.strictResponse = response == "rejected"
            ? .rejected(code: "rejected", message: "Rejected") : .timedOut
        hud.hide()

        await fixture.launcher.start(.landingPage, cwd: "/tmp/quick-start")
        #expect(!hud.visibilityStore.isVisible(for: 777))
        #expect(!hud.target.isVisible)

        fixture.launcher.resume()
        #expect(hud.visibilityStore.isVisible(for: 777))
        #expect(hud.target.isVisible && hud.target.isKey)
        #expect(fixture.rootClient.sentCommands.count == 1)
    }

    @Test(arguments: ["accepted", "resume", "success-open"])
    func everyOpenEntryPointRestoresOnlyItsHUDAndOpensThePickle(entryPoint: String) async throws {
        var presentSession: (String) -> Void = { _ in }
        let fixture = makeFixture(sessionIDs: ["quick-1"], presentSessionInHUD: { presentSession($0) })
        let hud = QuickStartHUDHarness(sessions: fixture.sessions)
        defer { try? FileManager.default.removeItem(at: hud.root) }
        presentSession = { sessionID in
            hud.manager.focusSession(id: sessionID, targetDisplayID: 777, persistVisibility: false)
        }
        project("quick-1", into: fixture.sessions)
        hud.hide()

        await fixture.launcher.start(.landingPage, cwd: "/tmp/quick-start")
        if entryPoint != "accepted" {
            hud.hide()
            if entryPoint == "resume" {
                fixture.launcher.resume()
            } else {
                fixture.launcher.openSessionInHUD(sessionID: "quick-1")
            }
        }

        #expect(hud.visibilityStore.isVisible(for: 777))
        #expect(!hud.visibilityStore.isVisible(for: 888))
        #expect(hud.target.isVisible && hud.target.isKey)
        #expect(!hud.other.isVisible && !hud.other.isKey)
        #expect(fixture.sessions.openSessionRequest?.targetDisplayID == 777)
        #expect(PickyHUDDockLayout.requestedOpenResolution(
            pendingSessionID: fixture.sessions.openSessionRequest?.sessionID,
            visibleIDs: fixture.sessions.sessions.map(\.id)
        ) == .open("quick-1"))
        #expect(fixture.rootClient.sentCommands.count == 1)
    }

    private func makeFixture(
        sessionIDs: [String],
        presentSessionInHUD: @escaping (String) -> Void = { _ in }
    ) -> QuickStartFixture {
        var remainingSessionIDs = sessionIDs
        let rootClient = QuickStartClient()
        let childSpawner = QuickStartChildSpawner()
        let sessions = PickySessionListViewModel(
            client: rootClient,
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: QuickStartSelectionStore(),
            archiveStore: QuickStartArchiveStore(),
            manualOrderStore: QuickStartManualOrderStore(),
            manualPickleChildSpawner: childSpawner,
            manualPickleSessionIdFactory: {
                precondition(!remainingSessionIDs.isEmpty)
                return remainingSessionIDs.removeFirst()
            },
            sessionProjectionStorage: PickyRegistrySessionProjectionStorage()
        )
        let suiteName = "PickyHubQuickStartLauncherTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated quick-start test defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let launcher = PickyHubQuickStartLauncher(
            sessions: sessions,
            defaultCwd: { "/tmp/default" },
            presentSessionInHUD: presentSessionInHUD,
            defaults: defaults,
            projectionTimeoutNanoseconds: 1_000_000_000
        )
        return QuickStartFixture(
            sessions: sessions,
            launcher: launcher,
            rootClient: rootClient,
            childSpawner: childSpawner
        )
    }

    private func project(_ sessionID: String, into sessions: PickySessionListViewModel) {
        let now = Date()
        let session = PickyAgentSession(
            id: sessionID,
            title: "Quick Start",
            status: .waiting_for_input,
            cwd: "/tmp/quick-start",
            createdAt: now,
            updatedAt: now,
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: []
        )
        sessions.apply(.protocolEvent(PickyEventEnvelope(
            id: "event-\(sessionID)",
            protocolVersion: "2026-07-23",
            timestamp: now,
            event: .sessionUpdated(session)
        )))
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for the quick-start test boundary")
    }
}

@MainActor
private final class QuickStartHUDHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PickyQuickStartHUD-\(UUID())")
    let target = QuickStartFocusPanel()
    let other = QuickStartFocusPanel()
    let visibilityStore: PickyHUDVisibilityStore
    let manager: PickyHUDOverlayManager

    init(sessions: PickySessionListViewModel) {
        let settings = PickySettingsStore(appSupportRoot: root)
        let visibility = PickyHUDVisibilityStore(settingsStore: settings)
        visibilityStore = visibility
        let panels: [CGDirectDisplayID: QuickStartFocusPanel] = [777: target, 888: other]
        manager = PickyHUDOverlayManager(
            viewModel: sessions,
            appearanceStore: PickyAppearanceStore(settingsStore: settings),
            fontScaleStore: PickyAppFontScaleStore(settingsStore: settings),
            visibilityStore: visibility,
            settingsStore: settings,
            voiceTargetHitTestRegistry: PickyVoiceTargetHitTestRegistry(),
            presentSessionPanels: { displayID in
                #expect(displayID == 777)
                #expect(visibility.isVisible(for: 777))
                PickyHUDSessionFocusPresenter.present(targetDisplayID: displayID, panelsByDisplayID: panels)
            }
        )
    }

    func hide() {
        visibilityStore.setAllVisible(false, persist: false)
        target.isVisible = false
        target.isKey = false
        other.isVisible = false
        other.isKey = false
    }
}

@MainActor
private final class QuickStartFocusPanel: PickyHUDSessionFocusPanelPresenting {
    var isVisible = false
    var isKey = false

    func orderFrontRegardless() { isVisible = true }
    func makeKey() { isKey = true }
}

@MainActor
private struct QuickStartFixture {
    let sessions: PickySessionListViewModel
    let launcher: PickyHubQuickStartLauncher
    let rootClient: QuickStartClient
    let childSpawner: QuickStartChildSpawner
}
