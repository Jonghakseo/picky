//
//  PickyFullscreenWorkInfoSnapshot.swift
//  Picky
//
//  Read-only projection for the fullscreen 작업 정보 panel.
//

import Foundation

struct PickyFullscreenWorkInfoSnapshot: Equatable {
    struct ContextUsage: Equatable {
        let tokens: Int?
        let contextWindow: Int
        let percent: Double?
    }

    struct Activity: Equatable {
        let label: String
        let summary: PickyActivitySummary

        var totalCount: Int {
            summary.read + summary.bash + summary.edit + summary.write + summary.thinking + summary.other
        }
    }

    struct Tool: Equatable, Identifiable {
        let id: String
        let name: String
        let status: String
        let preview: String?
        let startedAt: Date?
        let endedAt: Date?
    }

    struct Artifact: Equatable, Identifiable {
        let id: String
        let kind: String
        let title: String
        let path: String?
        let url: URL?
        let updatedAt: Date
    }

    struct PendingInput: Equatable {
        let extensionRequestTitle: String?
        let extensionRequestMethod: String?
        let queuedSteerCount: Int
        let queuedFollowUpCount: Int

        var isEmpty: Bool {
            extensionRequestTitle == nil
                && extensionRequestMethod == nil
                && queuedSteerCount == 0
                && queuedFollowUpCount == 0
        }
    }

    let sessionID: String
    let title: String
    let status: PickySessionStatus
    let createdAt: Date
    let updatedAt: Date
    let notifyMainOnCompletion: Bool?
    let isPinned: Bool
    let isArchived: Bool
    let assistantModel: String?
    let assistantThinkingLevel: PickyMainAgentThinkingLevel?
    let canResumePiSession: Bool
    let contextUsage: ContextUsage?
    let activity: Activity?
    let tools: [Tool]
    let changedFiles: [PickyChangedFile]
    let artifacts: [Artifact]
    let pendingInput: PendingInput

    static func make(from session: PickySessionListViewModel.SessionCard) -> Self {
        let assistantRun = PickyFullscreenAssistantRunResolver.effectiveAssistantRun(for: session)
        return Self(
            sessionID: session.id,
            title: session.title,
            status: session.status,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            notifyMainOnCompletion: session.notifyMainOnCompletion,
            isPinned: session.pinned,
            isArchived: session.archived,
            assistantModel: assistantRun?.model,
            assistantThinkingLevel: assistantRun?.thinkingLevel,
            canResumePiSession: session.piSessionFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            contextUsage: session.contextUsage.map {
                ContextUsage(tokens: $0.tokens, contextWindow: $0.contextWindow, percent: $0.percent)
            },
            activity: activity(from: session),
            tools: session.tools.map {
                Tool(
                    id: $0.toolCallId,
                    name: $0.name,
                    status: $0.status,
                    preview: firstNonEmpty($0.preview, $0.resultPreview, $0.argsPreview),
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt
                )
            },
            changedFiles: session.changedFiles,
            artifacts: session.artifacts.map {
                Artifact(id: $0.id, kind: $0.kind, title: $0.title, path: $0.path, url: $0.url, updatedAt: $0.updatedAt)
            },
            pendingInput: PendingInput(
                extensionRequestTitle: firstNonEmpty(session.pendingExtensionUiRequest?.title, session.pendingExtensionUiRequest?.prompt),
                extensionRequestMethod: session.pendingExtensionUiRequest?.method,
                queuedSteerCount: session.queuedSteers.count,
                queuedFollowUpCount: session.queuedFollowUps.count
            )
        )
    }

    private static func activity(from session: PickySessionListViewModel.SessionCard) -> Activity? {
        if session.status == .running {
            return Activity(label: "현재 턴", summary: session.activitySummary)
        }
        guard let snapshot = session.messages.reversed().compactMap(\.activitySnapshot).first else { return nil }
        return Activity(label: "마지막 턴", summary: snapshot)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }
}
