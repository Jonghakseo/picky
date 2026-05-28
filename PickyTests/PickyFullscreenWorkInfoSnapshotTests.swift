//
//  PickyFullscreenWorkInfoSnapshotTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenWorkInfoSnapshot")
struct PickyFullscreenWorkInfoSnapshotTests {
    @Test func projectsEmptySessionWithoutInventingUnavailableData() {
        let session = card(
            status: .completed,
            piSessionFilePath: nil,
            tools: [],
            artifacts: [],
            changedFiles: [],
            messages: [],
            contextUsage: nil,
            currentAssistantRun: nil,
            pendingExtensionUiRequest: nil
        )

        let snapshot = PickyFullscreenWorkInfoSnapshot.make(from: session)

        #expect(snapshot.status == .completed)
        #expect(snapshot.assistantModel == nil)
        #expect(snapshot.assistantThinkingLevel == nil)
        #expect(!snapshot.canResumePiSession)
        #expect(snapshot.contextUsage == nil)
        #expect(snapshot.activity == nil)
        #expect(snapshot.tools.isEmpty)
        #expect(snapshot.changedFiles.isEmpty)
        #expect(snapshot.artifacts.isEmpty)
        #expect(snapshot.pendingInput.isEmpty)
    }

    @Test func projectsExistingSessionDataOnly() {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_120)
        let artifactDate = Date(timeIntervalSince1970: 1_800_000_090)
        let session = card(
            status: .running,
            createdAt: createdAt,
            updatedAt: updatedAt,
            piSessionFilePath: "/tmp/pi-session.jsonl",
            tools: [
                PickyToolActivity(
                    toolCallId: "tool-1",
                    name: "bash",
                    status: "succeeded",
                    preview: "ran tests",
                    startedAt: createdAt,
                    endedAt: updatedAt
                )
            ],
            artifacts: [
                PickyArtifact(id: "artifact-1", kind: "report", title: "Report", path: "/tmp/report.md", url: nil, updatedAt: artifactDate)
            ],
            changedFiles: [
                PickyChangedFile(path: "Picky/File.swift", status: "modified", summary: "Updated UI")
            ],
            messages: [
                message("m1", activitySnapshot: PickyActivitySummary(read: 1, write: 1))
            ],
            queuedSteers: [PickyQueueItem(text: "steer", enqueuedAt: createdAt)],
            queuedFollowUps: [PickyQueueItem(text: "follow", enqueuedAt: updatedAt)],
            activitySummary: PickyActivitySummary(edit: 2, bash: 1, thinking: 3),
            contextUsage: PickyContextUsage(tokens: 12_345, contextWindow: 200_000, percent: 0.12),
            currentAssistantRun: PickyAssistantRunMetadata(model: "openai/gpt-5", thinkingLevel: .high),
            pendingExtensionUiRequest: extensionRequest(createdAt: createdAt),
            notifyMainOnCompletion: true,
            archived: true,
            pinned: true
        )

        let snapshot = PickyFullscreenWorkInfoSnapshot.make(from: session)

        #expect(snapshot.sessionID == "session-1")
        #expect(snapshot.title == "Test Pickle")
        #expect(snapshot.createdAt == createdAt)
        #expect(snapshot.updatedAt == updatedAt)
        #expect(snapshot.notifyMainOnCompletion == true)
        #expect(snapshot.isPinned)
        #expect(snapshot.isArchived)
        #expect(snapshot.assistantModel == "openai/gpt-5")
        #expect(snapshot.assistantThinkingLevel == .high)
        #expect(snapshot.canResumePiSession)
        #expect(snapshot.contextUsage == .init(tokens: 12_345, contextWindow: 200_000, percent: 0.12))
        #expect(snapshot.activity == .init(label: "현재 턴", summary: PickyActivitySummary(edit: 2, bash: 1, thinking: 3)))
        #expect(snapshot.tools == [
            .init(id: "tool-1", name: "bash", status: "succeeded", preview: "ran tests", startedAt: createdAt, endedAt: updatedAt)
        ])
        #expect(snapshot.changedFiles == [PickyChangedFile(path: "Picky/File.swift", status: "modified", summary: "Updated UI")])
        #expect(snapshot.artifacts == [
            .init(id: "artifact-1", kind: "report", title: "Report", path: "/tmp/report.md", url: nil, updatedAt: artifactDate)
        ])
        #expect(snapshot.pendingInput.extensionRequestTitle == "Confirm")
        #expect(snapshot.pendingInput.extensionRequestMethod == "ask_user_question")
        #expect(snapshot.pendingInput.queuedSteerCount == 1)
        #expect(snapshot.pendingInput.queuedFollowUpCount == 1)
    }

    @Test func completedSessionUsesLatestMessageActivitySnapshot() {
        let older = PickyActivitySummary(read: 1)
        let latest = PickyActivitySummary(edit: 1, bash: 2)
        let session = card(
            status: .completed,
            messages: [
                message("m1", activitySnapshot: older),
                message("m2", activitySnapshot: nil),
                message("m3", activitySnapshot: latest)
            ],
            activitySummary: PickyActivitySummary(write: 9)
        )

        let snapshot = PickyFullscreenWorkInfoSnapshot.make(from: session)

        #expect(snapshot.activity == PickyFullscreenWorkInfoSnapshot.Activity(label: "마지막 턴", summary: latest))
    }

    private func card(
        status: PickySessionStatus = .completed,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_060),
        piSessionFilePath: String? = nil,
        tools: [PickyToolActivity] = [],
        artifacts: [PickyArtifact] = [],
        changedFiles: [PickyChangedFile] = [],
        messages: [PickySessionMessage] = [],
        queuedSteers: [PickyQueueItem] = [],
        queuedFollowUps: [PickyQueueItem] = [],
        activitySummary: PickyActivitySummary = .zero,
        contextUsage: PickyContextUsage? = nil,
        currentAssistantRun: PickyAssistantRunMetadata? = nil,
        pendingExtensionUiRequest: PickyExtensionUiRequest? = nil,
        notifyMainOnCompletion: Bool? = nil,
        archived: Bool? = nil,
        pinned: Bool? = nil
    ) -> PickySessionListViewModel.SessionCard {
        PickyAgentSession(
            id: "session-1",
            title: "Test Pickle",
            status: status,
            piSessionFilePath: piSessionFilePath,
            createdAt: createdAt,
            updatedAt: updatedAt,
            logs: [],
            tools: tools,
            artifacts: artifacts,
            changedFiles: changedFiles,
            messages: messages,
            queuedSteers: queuedSteers,
            queuedFollowUps: queuedFollowUps,
            activitySummary: activitySummary,
            contextUsage: contextUsage,
            currentAssistantRun: currentAssistantRun,
            pendingExtensionUiRequest: pendingExtensionUiRequest,
            notifyMainOnCompletion: notifyMainOnCompletion,
            archived: archived,
            pinned: pinned
        ).toSessionCard()
    }

    private func message(_ id: String, activitySnapshot: PickyActivitySummary?) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: .agentText,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            originatedBy: nil,
            text: nil,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: activitySnapshot,
            errorContext: nil,
            errorMessage: nil
        )
    }

    private func extensionRequest(createdAt: Date) -> PickyExtensionUiRequest {
        PickyExtensionUiRequest(
            id: "request-1",
            sessionId: "session-1",
            method: "ask_user_question",
            title: "Confirm",
            prompt: "Continue?",
            description: nil,
            options: nil,
            questions: nil,
            createdAt: createdAt,
            text: nil,
            notifyType: nil
        )
    }
}

private extension PickyAgentSession {
    func toSessionCard() -> PickySessionListViewModel.SessionCard {
        PickySessionListViewModel.SessionCard.fromAgentSession(self)
    }
}
