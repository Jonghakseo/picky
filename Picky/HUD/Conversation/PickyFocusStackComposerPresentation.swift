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

/// What pressing send (or return) does. While a scheduled message is being
/// edited the composer saves that message instead of sending a new one.
enum PickyComposerSubmitRoute: Equatable {
    case send(PickyConversationComposerSubmitKind?)
    case saveScheduledEdit(id: String, kind: PickyScheduledMessageRow.Kind)

    static func route(
        editingScheduledRowID: String?,
        editingScheduledRowKind: PickyScheduledMessageRow.Kind?,
        submitKind: PickyConversationComposerSubmitKind?
    ) -> Self {
        guard let editingScheduledRowID, let editingScheduledRowKind else { return .send(submitKind) }
        return .saveScheduledEdit(id: editingScheduledRowID, kind: editingScheduledRowKind)
    }
}

enum PickyConversationComposerReturnKeyAction: Equatable {
    case insertNewline
    case submitDefault
    case submitOptionReturn
}

enum PickyConversationComposerUpArrowKeyAction: Equatable {
    case restoreQueue
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

    /// Compact model name for the composer settings chip (no vendor prefix).
    var chipModelText: String? {
        modelIdentifier.map(PickyAssistantRunMetadata.compactModelName)
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
