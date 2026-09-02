//
//  PickyFocusStackComposerPresentation.swift
//  Picky
//
//  Pure Focus Stack projections for composer-adjacent controls.
//

import Foundation

enum PickyConversationComposerSubmitKind: Equatable {
    case steer
    case followUp
}

enum PickyConversationComposerReturnKeyAction: Equatable {
    case insertNewline
    case submitDefault
    case submitOptionReturn
}

enum PickyConversationComposerUpArrowKeyAction: Equatable {
    case clearQueue
    case navigateAutocomplete
    case recallPreviousMessage
}

/// Mirrors agentd's `parseUserBashInput` (session-supervisor.ts): `!` invokes
/// bash with the command's output added to Pi's context on the next turn,
/// `!!` invokes bash with the output excluded. The composer uses this state
/// to recolor its border, swap the send icon, and surface a corner badge so
/// the user can see at a glance that pressing return will execute, not chat.
enum PickyComposerBashMode: Equatable {
    case none
    case visible
    case `private`
}

enum PickyComposerBorderState: Equatable {
    case fileDrop
    case bash
    case running
    case focused
    case rest
}

struct PickyComposerSubmitPresentation: Equatable {
    let label: String
    let iconName: String
    let accessibilityLabel: String

    init(kind: PickyConversationComposerSubmitKind?, bashMode: PickyComposerBashMode) {
        switch kind {
        case .steer:
            label = L10n.t("hud.composer.submit.steer")
        case .followUp:
            label = L10n.t("hud.composer.submit.followUp")
        case nil:
            label = L10n.t("hud.composer.submit.send")
        }
        switch bashMode {
        case .none:
            iconName = kind == .followUp ? "arrow.turn.down.right" : "arrow.up"
        case .visible, .private:
            iconName = "play.fill"
        }
        accessibilityLabel = label
    }
}

struct PickyComposerRuntimePresentation: Equatable {
    let modelText: String?
    let thinkingText: String?
    private let modelIdentifier: String?

    init(assistantRun: PickyAssistantRunMetadata?) {
        let modelIdentifier = Self.normalized(assistantRun?.model)
        self.modelIdentifier = modelIdentifier
        modelText = modelIdentifier.map(Self.visibleModelName)
        thinkingText = assistantRun?.thinkingLevel.map { Self.normalized($0.rawValue) } ?? nil
    }

    var hasControls: Bool {
        modelText != nil || thinkingText != nil
    }

    var modelLabel: String? {
        modelIdentifier.map { L10n.t("hud.conversation.meta.model", $0) }
    }

    var thinkingLabel: String? {
        thinkingText.map { L10n.t("hud.conversation.meta.thinking", $0) }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func visibleModelName(_ identifier: String) -> String {
        identifier.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? identifier
    }
}

enum PickyComposerEditorHeightPolicy {
    /// The editor reserves a two-line writing canvas, grows through four lines,
    /// then leaves additional content to the native scroll view.
    static let minimumHeight = DS.Spacing.space6 * 2
    static let maximumHeight: CGFloat = 78
    private static let estimatedLineHeight: CGFloat = 18
    private static let textInsetHeight: CGFloat = 2

    static func height(forMeasuredContentHeight contentHeight: CGFloat) -> CGFloat {
        min(maximumHeight, max(minimumHeight, ceil(contentHeight)))
    }

    static func height(for text: String) -> CGFloat {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let measuredHeight = CGFloat(lineCount) * estimatedLineHeight + (textInsetHeight * 2)
        return height(forMeasuredContentHeight: measuredHeight)
    }

    static func transientGrowth(forEditorHeight editorHeight: CGFloat) -> CGFloat {
        max(0, height(forMeasuredContentHeight: editorHeight) - minimumHeight)
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
        case .restore: return L10n.t("hud.queue.restoring")
        case .clear: return L10n.t("hud.queue.clearing")
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
            case .steer: return L10n.t("hud.composer.submit.steer")
            case .followUp: return L10n.t("hud.composer.submit.followUp")
            }
        }
    }

    let kind: Kind
    let count: Int
    let mode: PickyQueueMode

    var id: Kind { kind }

    var modeLabel: String {
        L10n.t(mode == .all ? "hud.queue.mode.all" : "hud.queue.mode.individual")
    }

    var accessibilityValue: String {
        L10n.t(
            count == 1 ? "hud.queue.item.one.accessibilityValue" : "hud.queue.item.many.accessibilityValue",
            Int64(count),
            kind.label,
            modeLabel
        )
    }
}

struct PickyQueueDockPresentation: Equatable {
    let kinds: [PickyQueueDockKindPresentation]
    let restoreAvailability: PickyQueuedInputRestoreAvailability

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
        restoreAvailability = PickyQueuedInputRestoreAvailability.resolve(visibleQueue: visibleQueue)
    }

    var isVisible: Bool {
        !kinds.isEmpty
    }

    var isRestoreEnabled: Bool {
        restoreAvailability == .available
    }

    var isClearEnabled: Bool {
        isVisible
    }

    var restoreHelp: String {
        switch restoreAvailability {
        case .blockedByScreenContext(let attachedImagesCount):
            L10n.t("hud.queue.restore.blockedByScreenContext.help", Int64(attachedImagesCount))
        case .available, .unavailable:
            L10n.t("hud.queue.restore.help")
        }
    }

    var restoreAccessibilityLabel: String {
        switch restoreAvailability {
        case .blockedByScreenContext(let attachedImagesCount):
            L10n.t("hud.queue.restore.blockedByScreenContext.accessibilityLabel", Int64(attachedImagesCount))
        case .available, .unavailable:
            L10n.t("hud.queue.restore.accessibilityLabel")
        }
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
