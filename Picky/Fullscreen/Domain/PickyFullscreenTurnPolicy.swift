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
    let statusMessages: [PickySessionMessage]
    let isCurrent: Bool
    let liveActivitySummary: PickyActivitySummary?
}

enum PickyFullscreenTurnPolicy {
    static func renderModels(
        from messages: [PickySessionMessage],
        sessionStatus: PickySessionStatus,
        liveActivitySummary: PickyActivitySummary? = nil
    ) -> [PickyFullscreenTurnRenderModel] {
        PickyTurnGrouper.groups(
            from: messages,
            sessionStatus: sessionStatus,
            liveActivitySummary: liveActivitySummary
        )
        .map(renderModel(from:))
        .filter { model in
            model.userMessage != nil || !model.bodyMessages.isEmpty || !model.statusMessages.isEmpty
        }
    }

    static func renderModel(from group: PickyTurnGroup) -> PickyFullscreenTurnRenderModel {
        let visibleBody = group.isCurrent
            ? currentTurnBodyMessages(from: group)
            : completedTurnBodyMessages(from: group.bodyMessages)
        let statuses = statusMessages(from: group.bodyMessages) + group.trailingCompactMessages
        return PickyFullscreenTurnRenderModel(
            id: group.id,
            userMessage: group.userMessage,
            bodyMessages: visibleBody,
            statusMessages: statuses,
            isCurrent: group.isCurrent,
            liveActivitySummary: group.liveActivitySummary
        )
    }

    static func completedTurnBodyMessages(from messages: [PickySessionMessage]) -> [PickySessionMessage] {
        if let lastAgentText = messages.last(where: { $0.kind == .agentText }) {
            return [lastAgentText]
        }
        if let lastAgentError = messages.last(where: { $0.kind == .agentError }) {
            return [lastAgentError]
        }
        return []
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
            case .agentQuestion, .agentError:
                output.append(message)
            case .system, .userText, .commandReceipt, .agentThinking:
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
