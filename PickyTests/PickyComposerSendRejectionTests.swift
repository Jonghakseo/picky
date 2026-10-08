//
//  PickyComposerSendRejectionTests.swift
//  PickyTests
//
//  A message the daemon refuses must come back with a reason, not vanish, and
//  an automatic runtime restart must be visible on the conversation card.
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyComposerSendRejectionTests {
    private let events = PickyProjectionEventFixtures()

    private func makeViewModel() -> (PickySessionListViewModel, FakePickyAgentClient) {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        let session = PickyAgentSession(
            id: "pickle-1", title: "Stuck Pickle", status: .blocked, cwd: "/tmp/project",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            logs: [], tools: [], artifacts: [], changedFiles: [], messages: []
        )
        viewModel.apply(.protocolEvent(events.snapshotEnvelope(session: session)))
        return (viewModel, client)
    }

    @Test func rejectedMessageThrowsTheRejectionAndIsNotRecordedAsSent() async throws {
        let (viewModel, client) = makeViewModel()
        client.sendAwaitingErrorResult = PickyErrorEvent(code: "runtimeRestarting", message: "Pickle runtime is restarting", commandId: nil)

        let error = await #expect(throws: PickyCommandRejection.self) {
            try await viewModel.composerSender.send(kind: .followUp, text: "  retry this  ", sessionID: "pickle-1")
        }

        #expect(error.map(PickyComposerSendFailurePolicy.message(for:)) == L10n.t("hud.composer.sendError.restarting"))
        #expect(client.sentCommands.last?.type == .followUp)
        #expect(client.sentCommands.last?.text == "retry this")
        #expect(viewModel.sessions.first { $0.id == "pickle-1" }?.lastRequestText != "retry this")
    }

    @Test func acceptedMessageIsRecordedAsTheLatestRequest() async throws {
        let (viewModel, client) = makeViewModel()

        try await viewModel.composerSender.send(kind: .steer, text: "continue", sessionID: "pickle-1")

        #expect(client.sentCommands.last?.type == .steer)
        #expect(viewModel.sessions.first { $0.id == "pickle-1" }?.lastRequestText == "continue")
        // Waits for the verdict, and a late ack is not mistaken for a failure.
        #expect(client.acknowledgementRequirements == [false])
    }

    @Test func failureMessagesNameTheReasonAndTheWayForward() {
        func message(_ code: String, _ detail: String = "detail") -> String {
            PickyComposerSendFailurePolicy.message(for: PickyCommandRejection(event: PickyErrorEvent(code: code, message: detail, commandId: nil)))
        }
        #expect(message("runtimeUnavailable") == L10n.t("hud.composer.sendError.unavailable"))
        #expect(message("bad_message", "Cannot steer an archived session") == L10n.t("hud.composer.sendError.generic", "Cannot steer an archived session"))
    }

    @Test func runtimeRecoveryFromTheDaemonReachesTheCardMetadata() throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        let recovery = PickyRuntimeRecovery(phase: .failed, updatedAt: Date(timeIntervalSince1970: 3))
        let session = PickyAgentSession(
            id: "pickle-2", title: "Failed restart", status: .blocked, cwd: "/tmp/project",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            logs: [], tools: [], artifacts: [], changedFiles: [], messages: [], runtimeRecovery: recovery
        )
        viewModel.apply(.protocolEvent(events.snapshotEnvelope(session: session)))

        #expect(viewModel.sessions.first { $0.id == "pickle-2" }?.runtimeRecovery == recovery)
    }
}

struct PickyRuntimeRecoveryBannerPresentationTests {
    private let at = Date(timeIntervalSince1970: 10)

    @Test func noRecoveryShowsNothing() {
        #expect(PickyRuntimeRecoveryBannerPresentation(recovery: nil, dismissedUpdate: nil, canDuplicate: true) == nil)
    }

    @Test func restartingOnlyInformsAndCannotBeDismissed() throws {
        let banner = try #require(PickyRuntimeRecoveryBannerPresentation(
            recovery: .init(phase: .restarting, updatedAt: at), dismissedUpdate: nil, canDuplicate: true))
        #expect(banner.tone == .progress)
        #expect(!banner.dismissible)
        #expect(!banner.offersDuplicate)
    }

    @Test func restartedNoticeStaysClosedOnlyForTheRestartTheUserDismissed() {
        let restarted = PickyRuntimeRecovery(phase: .restarted, updatedAt: at)
        #expect(PickyRuntimeRecoveryBannerPresentation(recovery: restarted, dismissedUpdate: nil, canDuplicate: true)?.dismissible == true)
        #expect(PickyRuntimeRecoveryBannerPresentation(recovery: restarted, dismissedUpdate: at, canDuplicate: true) == nil)
        let later = PickyRuntimeRecovery(phase: .restarted, updatedAt: at.addingTimeInterval(60))
        #expect(PickyRuntimeRecoveryBannerPresentation(recovery: later, dismissedUpdate: at, canDuplicate: true) != nil)
    }

    @Test func failedRestartOffersDuplicateOnlyWhenThereIsASessionFile() throws {
        let failed = PickyRuntimeRecovery(phase: .failed, updatedAt: at)
        let withFile = try #require(PickyRuntimeRecoveryBannerPresentation(recovery: failed, dismissedUpdate: nil, canDuplicate: true))
        #expect(withFile.offersDuplicate)
        #expect(withFile.tone == .warning)
        let withoutFile = try #require(PickyRuntimeRecoveryBannerPresentation(recovery: failed, dismissedUpdate: nil, canDuplicate: false))
        #expect(!withoutFile.offersDuplicate)
        #expect(withoutFile.detailKey == "hud.runtimeRecovery.failed.bodyNoDuplicate")
    }

    @Test func noPresenceLineWhileTheRuntimeRestarts() {
        #expect(PickyConversationPresencePresentation.make(
            isRunning: true, isWaitingForInput: false, activeTool: nil, startedAt: nil, isRuntimeRestarting: true) == nil)
        #expect(PickyConversationPresencePresentation.make(
            isRunning: true, isWaitingForInput: false, activeTool: nil, startedAt: nil)?.phase == .thinking)
    }
}
