//
//  PickyFullscreenTurnPolicy.swift
//  Picky
//
//  Pure visibility policy for fullscreen conversation turns. Fullscreen keeps
//  completed turns readable by showing the final assistant answer only, while
//  the current turn may surface live progress.
//

import Foundation

struct PickyFullscreenTurnRenderModel: Equatable, Identifiable {
    let id: String
    let userMessage: PickySessionMessage?
    let bodyMessages: [PickySessionMessage]
    let intermediateMessages: [PickySessionMessage]
    let statusMessages: [PickySessionMessage]
    let workDurationSeconds: Int?
    let isCurrent: Bool
    let liveActivitySummary: PickyActivitySummary?
}

enum PickyFullscreenTurnPolicy {
    static func renderModels(
        from messages: [PickySessionMessage],
        sessionStatus: PickySessionStatus,
        liveActivitySummary: PickyActivitySummary? = nil,
        completedTurnIDs: Set<String> = []
    ) -> [PickyFullscreenTurnRenderModel] {
        let groups = PickyTurnGrouper.groups(
            from: messages,
            sessionStatus: sessionStatus,
            liveActivitySummary: liveActivitySummary
        )
        return renderModels(from: groups, completedTurnIDs: completedTurnIDs)
    }

    static func renderModels(
        from groups: [PickyTurnGroup],
        completedTurnIDs: Set<String> = []
    ) -> [PickyFullscreenTurnRenderModel] {
        groups
            .map { renderModel(from: $0, completedTurnIDs: completedTurnIDs) }
            .filter { model in
                model.userMessage != nil || !model.bodyMessages.isEmpty || !model.statusMessages.isEmpty
            }
    }

    static func renderModel(
        from group: PickyTurnGroup,
        completedTurnIDs: Set<String> = []
    ) -> PickyFullscreenTurnRenderModel {
        // Mirror the HUD turn-card latch at the fullscreen render-policy level:
        // once a turn has been observed as completed, do not let the
        // status-before-user-message follow-up race promote that same group
        // back into live-progress rendering. The next real follow-up turn has a
        // new user-message id, so it can still become current normally.
        let isLatchedComplete = completedTurnIDs.contains(group.id)
        let isCurrent = group.isCurrent && !isLatchedComplete
        let visibleBody = isCurrent
            ? currentTurnBodyMessages(from: group)
            : completedTurnBodyMessages(from: group.bodyMessages)
        let intermediateMessages = intermediateMessages(for: group, isCurrent: isCurrent)
        let statuses = statusMessages(from: group.bodyMessages) + group.trailingCompactMessages
        return PickyFullscreenTurnRenderModel(
            id: group.id,
            userMessage: group.userMessage,
            bodyMessages: visibleBody,
            intermediateMessages: intermediateMessages,
            statusMessages: statuses,
            workDurationSeconds: isCurrent ? nil : workDurationSeconds(for: group),
            isCurrent: isCurrent,
            liveActivitySummary: isCurrent ? group.liveActivitySummary : nil
        )
    }

    static func completedTurnBodyMessages(from messages: [PickySessionMessage]) -> [PickySessionMessage] {
        if let finalOutput = messages.last(where: { $0.kind == .agentText || $0.kind == .agentError }) {
            return [finalOutput]
        }
        return []
    }

    static func intermediateMessages(for group: PickyTurnGroup, isCurrent: Bool) -> [PickySessionMessage] {
        guard !isCurrent else { return [] }
        let finalOutputID = completedTurnBodyMessages(from: group.bodyMessages).first?.id
        return group.bodyMessages.filter { message in
            guard message.id != finalOutputID else { return false }
            switch message.kind {
            case .agentThinking, .system, .userText:
                return false
            case .agentText, .agentActivity, .agentError, .commandReceipt, .agentQuestion:
                return true
            }
        }
    }

    static func workDurationSeconds(for group: PickyTurnGroup) -> Int? {
        let firstAt = group.userMessage?.createdAt ?? group.bodyMessages.first?.createdAt
        let lastAt = group.bodyMessages.last?.createdAt ?? group.userMessage?.createdAt
        guard let firstAt, let lastAt else { return nil }
        let seconds = Int(lastAt.timeIntervalSince(firstAt))
        return seconds >= 1 ? seconds : nil
    }

    static func currentTurnBodyMessages(from group: PickyTurnGroup) -> [PickySessionMessage] {
        var output: [PickySessionMessage] = []
        let latestAgentTextID = group.bodyMessages.last(where: { $0.kind == .agentText })?.id

        for message in group.bodyMessages {
            switch message.kind {
            case .agentText:
                if message.id == latestAgentTextID { output.append(message) }
            case .agentActivity:
                if message.activitySnapshot?.visibleToolCallItems.isEmpty == false { output.append(message) }
            case .agentQuestion, .agentError, .agentThinking:
                output.append(message)
            case .system, .userText, .commandReceipt:
                break
            }
        }

        return output
    }

    static func statusMessages(from messages: [PickySessionMessage]) -> [PickySessionMessage] {
        messages.filter { message in
            guard message.kind == .system else { return false }
            return message.isCompactCompletionMessage
                || message.isCompactFailureMessage
                || message.notifyType != nil
        }
    }
}
