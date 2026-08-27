//
//  PickyFocusStackComposerPresentation.swift
//  Picky
//
//  Pure Focus Stack projections for composer-adjacent controls.
//

import Foundation

struct PickyComposerSubmitPresentation: Equatable {
    let label: String
    let iconName: String
    let accessibilityLabel: String

    init(kind: PickyConversationComposerSubmitKind?, bashMode: PickyComposerBashMode) {
        switch kind {
        case .steer:
            label = "Steer"
        case .followUp:
            label = "Follow-up"
        case nil:
            label = "Send"
        }
        iconName = bashMode == .none ? "paperplane.fill" : "play.fill"
        accessibilityLabel = label
    }
}

struct PickyComposerRuntimePresentation: Equatable {
    let modelText: String?
    let thinkingText: String?

    init(assistantRun: PickyAssistantRunMetadata?) {
        modelText = Self.normalized(assistantRun?.model)
        thinkingText = assistantRun?.thinkingLevel.map { Self.normalized($0.rawValue) } ?? nil
    }

    var hasControls: Bool {
        modelText != nil || thinkingText != nil
    }

    var modelLabel: String? {
        modelText.map { "Model: \($0)" }
    }

    var thinkingLabel: String? {
        thinkingText.map { "Thinking: \($0)" }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PickyQueueEvidenceTone: Equatable {
    case neutral
}

enum PickyQueueDockLayout: Equatable {
    case inline
    case stacked
    case constrained

    init(
        cardWidth: CGFloat,
        heightTier: PickyConversationFocusStackHeightTier = .regular
    ) {
        if heightTier == .constrained {
            self = .constrained
        } else {
            self = cardWidth < 400 ? .stacked : .inline
        }
    }
}

enum PickyQueueDockCommand: Equatable {
    case restoreThenClear(PickyQueueClearKind)
    case clearOnly(PickyQueueClearKind)
}

enum PickyQueueDockAction: Equatable {
    case restore
    case clear

    var inFlightLabel: String {
        switch self {
        case .restore: return "Restoring…"
        case .clear: return "Clearing…"
        }
    }

    var command: PickyQueueDockCommand {
        switch self {
        case .restore: return .restoreThenClear(.all)
        case .clear: return .clearOnly(.all)
        }
    }
}

struct PickyQueueDockKindPresentation: Equatable, Identifiable {
    enum Kind: Hashable {
        case steer
        case followUp

        var label: String {
            switch self {
            case .steer: return "Steer"
            case .followUp: return "Follow-up"
            }
        }
    }

    let kind: Kind
    let count: Int
    let mode: PickyQueueMode

    var id: Kind { kind }

    var modeLabel: String {
        mode == .all ? "all together" : "individually"
    }

    var accessibilityValue: String {
        "\(count) \(kind.label) \(count == 1 ? "item" : "items"), \(modeLabel)"
    }
}

struct PickyQueueDockPresentation: Equatable {
    let kinds: [PickyQueueDockKindPresentation]

    init(
        visibleQueue: PickyVisibleQueue,
        steeringMode: PickyQueueMode,
        followUpMode: PickyQueueMode
    ) {
        var kinds: [PickyQueueDockKindPresentation] = []
        if !visibleQueue.steers.isEmpty {
            kinds.append(.init(kind: .steer, count: visibleQueue.steers.count, mode: steeringMode))
        }
        if !visibleQueue.followUps.isEmpty {
            kinds.append(.init(kind: .followUp, count: visibleQueue.followUps.count, mode: followUpMode))
        }
        self.kinds = kinds
    }

    var isVisible: Bool {
        !kinds.isEmpty
    }

    var accessibilityValue: String {
        kinds.map(\.accessibilityValue).joined(separator: "; ")
    }
}

struct PickyInlineTerminalContinuityPresentation: Equatable {
    let statusText: String
    let toolText: String?
    let todoText: String?
    let elapsedText: String?

    init(session: PickyConversationSessionCard, now: Date = .now) {
        statusText = PickyConversationStatusPresentation(status: session.status).label
        toolText = session.activeTool?.name
        todoText = PickyTodoProgressPresentation(state: session.todoState)?.countText
        let start = session.activeTool?.startedAt ?? PickyTodoProgressPresentation(state: session.todoState)?.updatedAt
        if session.status == .running, let start {
            elapsedText = PickyTurnSummary(
                stepCount: 0,
                toolCount: 0,
                elapsedSeconds: max(0, Int(now.timeIntervalSince(start))),
                showsStepCount: false
            ).elapsedDisplayText
        } else {
            elapsedText = nil
        }
    }

    var accessibilityValue: String {
        [statusText, toolText, todoText, elapsedText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
