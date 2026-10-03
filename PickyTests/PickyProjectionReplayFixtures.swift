//
//  PickyProjectionReplayFixtures.swift
//  PickyTests
//

import Foundation
@testable import Picky

@MainActor
enum PickyProjectionReplayFixtures {
    static let bootstrapDate = Date(timeIntervalSince1970: 1_787_544_000)
    static let terminalDate = Date(timeIntervalSince1970: 1_787_544_007)
    static let terminalSessionID = "terminal-session"
    static let terminalFinalAnswer = "Completed the investigation. Review https://github.com/creatrip/picky/pull/123 for the implementation."

    static func makeViewModel(
        notificationCenter: PickyNoopNotificationCenter = PickyNoopNotificationCenter(),
        selectedSessionID: String? = nil,
        sessionProjectionStorage: (any PickySessionProjectionStorage)? = nil
    ) -> PickySessionListViewModel {
        makeViewModelWithSelectionStore(
            notificationCenter: notificationCenter,
            selectedSessionID: selectedSessionID,
            sessionProjectionStorage: sessionProjectionStorage
        ).viewModel
    }

    /// Exposes the injected store so a test can observe the persisted
    /// selection, not just the view model's published mirror.
    static func makeViewModelWithSelectionStore(
        notificationCenter: PickyNoopNotificationCenter = PickyNoopNotificationCenter(),
        selectedSessionID: String? = nil,
        sessionProjectionStorage: (any PickySessionProjectionStorage)? = nil
    ) -> (viewModel: PickySessionListViewModel, selectionStore: ProjectionReplaySelectionStore) {
        let selectionStore = ProjectionReplaySelectionStore(selectedSessionID: selectedSessionID)
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: notificationCenter,
            selectionStore: selectionStore,
            archiveStore: ProjectionReplayArchiveStore(),
            manualOrderStore: ProjectionReplayManualOrderStore(),
            composerDraftStore: ProjectionReplayComposerDraftStore(),
            composerAttachmentDraftStore: ProjectionReplayComposerAttachmentDraftStore(),
            sessionProjectionStorage: sessionProjectionStorage
        )
        return (viewModel, selectionStore)
    }

    static func apply(_ envelope: PickyEventEnvelope, to viewModel: PickySessionListViewModel) {
        viewModel.apply(.protocolEvent(envelope))
    }

    /// The daemon bootstraps a connection with one `sessionProjectionSnapshot`
    /// per session, in descending `updatedAt` order.
    static func bootstrapSnapshotEvents(using builder: PickyProjectionEventFixtures) -> [PickyEventEnvelope] {
        lightweightBootstrapSessions().reversed().map { session in
            builder.snapshotEnvelope(
                id: "bootstrap-\(session.id)",
                session: session,
                timestamp: bootstrapDate
            )
        }
    }

    static func bootstrapEnvelope(id: String, event: PickyEvent) -> PickyEventEnvelope {
        PickyEventEnvelope(
            id: id,
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: bootstrapDate,
            event: event
        )
    }

    static func lightweightBootstrapSessions() -> [PickyAgentSession] {
        (0..<94).map { index in
            bootstrapSession(
                id: String(format: "bootstrap-%03d", index),
                index: index,
                status: index.isMultiple(of: 11) ? .completed : .running,
                archived: index.isMultiple(of: 17),
                messages: [],
                messageJournalAvailable: false
            )
        }
    }

    static func hydratedBootstrapSessions() -> [PickyAgentSession] {
        lightweightBootstrapSessions().enumerated().map { index, summary in
            bootstrapSession(
                id: summary.id,
                index: index,
                status: summary.status,
                archived: summary.archived ?? false,
                messages: bootstrapHydrationMessages(for: index),
                messageJournalAvailable: true
            )
        }
    }

    static func bootstrapSession(
        id: String,
        index: Int,
        status: PickySessionStatus,
        archived: Bool,
        messages: [PickySessionMessage],
        messageJournalAvailable: Bool
    ) -> PickyAgentSession {
        let createdAt = Date(timeIntervalSince1970: 1_787_500_000 + Double(index))
        return PickyAgentSession(
            id: id,
            title: "Bootstrap session \(index)",
            status: status,
            cwd: nil,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1),
            lastSummary: status == .completed ? "Completed historically" : "Hydrating",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: [],
            messages: messages,
            messageJournalAvailable: messageJournalAvailable,
            archived: archived
        )
    }

    static func terminalSession(
        status: PickySessionStatus,
        messages: [PickySessionMessage],
        messageJournalAvailable: Bool,
        artifacts: [PickyArtifact],
        finalAnswer: String? = nil
    ) -> PickyAgentSession {
        PickyAgentSession(
            id: terminalSessionID,
            title: "Terminal completion replay",
            status: status,
            cwd: nil,
            createdAt: Date(timeIntervalSince1970: 1_787_544_000),
            updatedAt: terminalDate,
            lastSummary: status == .completed ? "Completed the investigation." : "Running terminal replay",
            finalAnswer: finalAnswer,
            logs: [],
            tools: [],
            artifacts: artifacts,
            changedFiles: [],
            messages: messages,
            messageJournalAvailable: messageJournalAvailable
        )
    }

    static func terminalMessage(
        id: String,
        kind: PickySessionMessageKind,
        text: String?,
        activity: PickyActivitySummary? = nil
    ) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: kind,
            createdAt: terminalDate,
            originatedBy: kind == .userText ? .user : .mainAgent,
            text: text,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: activity,
            errorContext: nil,
            errorMessage: nil
        )
    }

    static func terminalArtifact() -> PickyArtifact {
        PickyArtifact(
            id: "link-github-terminal",
            kind: "github",
            title: "#123",
            path: nil,
            url: URL(string: "https://github.com/creatrip/picky/pull/123"),
            updatedAt: terminalDate
        )
    }

    /// App-bound v2 projection derived from the deterministic agentd terminal
    /// baseline. The tool and activity frames preserve the captured order:
    /// thinking activity, thinking message, read activity, running tool,
    /// succeeded tool, then the terminal activity reset and completion patch.
    static func terminalReplayEnvelopes(using builder: PickyProjectionEventFixtures) -> [PickyEventEnvelope] {
        let artifact = terminalArtifact()
        let mutations: [[String]] = [
            [PickyProjectionEventFixtures.activitySetMutation(PickyActivitySummary(thinking: 1))],
            [PickyProjectionEventFixtures.messageAppendMutation(terminalMessage(id: "thinking-terminal", kind: .agentThinking, text: "Preparing the final result."))],
            [PickyProjectionEventFixtures.activitySetMutation(PickyActivitySummary(thinking: 1, read: 1))],
            [PickyProjectionEventFixtures.toolUpsertMutation(PickyToolActivity(toolCallId: "tool-read", name: "read", status: "running", preview: "Read the session state", endedAt: nil))],
            [PickyProjectionEventFixtures.toolUpsertMutation(PickyToolActivity(toolCallId: "tool-read", name: "read", status: "succeeded", preview: "Read the session state", resultPreview: "state loaded", endedAt: terminalDate))],
            [PickyProjectionEventFixtures.messageAppendMutation(terminalMessage(id: "assistant-terminal", kind: .agentText, text: terminalFinalAnswer))],
            [PickyProjectionEventFixtures.messageRemoveMutation(messageID: "thinking-terminal")],
            [PickyProjectionEventFixtures.messageAppendMutation(terminalMessage(id: "activity-terminal", kind: .agentActivity, text: nil, activity: PickyActivitySummary(thinking: 1, read: 1)))],
            [PickyProjectionEventFixtures.activitySetMutation(.zero)],
            [
                PickyProjectionEventFixtures.metaPatchMutation("\"status\":\"completed\",\"lastSummary\":\"Completed the investigation.\""),
                PickyProjectionEventFixtures.finalAnswerSetMutation(terminalFinalAnswer),
            ],
            [PickyProjectionEventFixtures.artifactUpsertMutation(artifact)],
        ]
        return mutations.enumerated().map { index, mutation in
            builder.transactionEnvelope(
                id: "terminal-event-\(index)",
                sessionID: terminalSessionID,
                mutations: mutation,
                timestamp: terminalDate
            )
        }
    }

    static func terminalEnvelope(_ event: PickyEvent) -> PickyEventEnvelope {
        PickyEventEnvelope(id: "terminal-event", protocolVersion: pickyAgentProtocolVersion, timestamp: terminalDate, event: event)
    }

    private static func bootstrapHydrationMessages(for index: Int) -> [PickySessionMessage] {
        let count = index < 2 ? 24 : 1
        return (0..<count).map { messageIndex in
            PickySessionMessage(
                id: "message-\(index)-\(messageIndex)",
                kind: .agentText,
                createdAt: Date(timeIntervalSince1970: 1_787_544_000 + Double(index * 100 + messageIndex)),
                originatedBy: .mainAgent,
                text: String(repeating: "hydrated message \(index)-\(messageIndex) ", count: index < 2 ? 32 : 1),
                question: nil,
                cancelledAt: nil,
                activitySnapshot: nil,
                errorContext: nil,
                errorMessage: nil
            )
        }
    }
}

final class ProjectionReplaySelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
    var screenContextTargetSticky = false

    init(selectedSessionID: String? = nil) {
        self.selectedSessionID = selectedSessionID
    }

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sessionID == nil ? false : sticky
    }
}

private final class ProjectionReplayArchiveStore: PickySessionArchiveStoring {
    var archivedSessionIDs = Set<String>()
    var manuallyArchivedSessionIDs = Set<String>()
}

private final class ProjectionReplayManualOrderStore: PickySessionManualOrderStoring {
    var manualOrder: [String] = []
}

private final class ProjectionReplayComposerDraftStore: PickyComposerDraftStoring {
    func draft(for _: String) -> String? { nil }
    func setDraft(_: String?, for _: String) {}
    func prune(knownSessionIDs _: Set<String>) {}
}

private final class ProjectionReplayComposerAttachmentDraftStore: PickyComposerAttachmentDraftStoring {
    func attachmentPaths(for _: String) -> [String] { [] }
    func setAttachmentPaths(_: [String], for _: String) {}
    func prune(knownSessionIDs _: Set<String>) {}
}
