//
//  PickyHubQuickStartLauncherTests.swift
//  PickyTests
//

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

    private func makeFixture(sessionIDs: [String]) -> QuickStartFixture {
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
private struct QuickStartFixture {
    let sessions: PickySessionListViewModel
    let launcher: PickyHubQuickStartLauncher
    let rootClient: QuickStartClient
    let childSpawner: QuickStartChildSpawner
}
