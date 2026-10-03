//
//  PickyConversationComposerView+Policy.swift
//  Picky
//
//  Pure composer policies: how a draft turns into a submission, which key
//  chord submits what, and which border state the editor shows. They stay
//  outside the view so they remain directly testable.
//

import AppKit
import SwiftUI

extension PickyConversationComposerView {
    static func composerBorderState(
        isDropTargeted: Bool,
        bashMode: PickyComposerBashMode,
        isRunning: Bool,
        isFocused: Bool
    ) -> PickyComposerBorderState {
        if isDropTargeted { return .fileDrop }
        if bashMode != .none { return .bash }
        if isRunning { return .running }
        if isFocused { return .focused }
        return .rest
    }

    /// Mirror of `parseUserBashInput` in agentd's session supervisor. Kept in
    /// sync intentionally: if the parser there changes, this needs to change
    /// too, otherwise the composer will lie about the submit action.
    static func bashMode(in text: String) -> PickyComposerBashMode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!") else { return .none }
        let isPrivate = trimmed.hasPrefix("!!")
        let body = isPrivate ? trimmed.dropFirst(2) : trimmed.dropFirst(1)
        let command = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .none }
        return isPrivate ? .private : .visible
    }

    static func draftText(afterAppendingDroppedFilePaths paths: [String], to draft: String) -> String {
        let normalizedPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedPaths.isEmpty else { return draft }

        let droppedText = normalizedPaths.joined(separator: "\n")
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return droppedText
        }
        if draft.hasSuffix("\n") {
            return draft + droppedText
        }
        return "\(draft)\n\(droppedText)"
    }

    static func shouldResetSlashCommandDismissal(newDraft: String, acceptedDraft: String?) -> Bool {
        newDraft != acceptedDraft
    }

    static func submissionText(draft: String, attachmentPaths: [String]) -> String {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = draftText(afterAppendingDroppedFilePaths: attachmentPaths, to: trimmedDraft)
        // With attachments present we intentionally do NOT let the message
        // trigger agentd's `!`/`!!` bash shortcut: the appended file paths
        // would be silently glued onto the command line and either run as
        // arguments to whatever bash command the user typed, or break out
        // of the prompt entirely. Prepending a single space defeats the
        // prefix check in `parseUserBashInput` without altering how Pi
        // reads the message body, so the user gets a regular prompt with
        // the attachments intact.
        if !attachmentPaths.isEmpty && merged.hasPrefix("!") {
            return " " + merged
        }
        return merged
    }

    static func returnKeyAction(for modifiers: EventModifiers) -> PickyConversationComposerReturnKeyAction {
        if modifiers.contains(.shift) { return .insertNewline }
        if modifiers.contains(.option) { return .submitOptionReturn }
        return .submitDefault
    }

    static func upArrowKeyAction(for modifiers: EventModifiers) -> PickyConversationComposerUpArrowKeyAction {
        if modifiers.contains(.option) { return .restoreQueue }
        if modifiers.isEmpty { return .recallPreviousMessage }
        return .navigateAutocomplete
    }

    static func previousUserMessageText(in context: PickyComposerMessageContext) -> String? {
        context.submittedUserMessages.last?.text
    }

    static func draftRestoringQueuedMessages(
        draft: String,
        queuedSteers: [PickyQueueItem],
        queuedFollowUps: [PickyQueueItem]
    ) -> String? {
        PickyQueuedInputDraftPolicy.draftRestoringQueuedInputs(
            draft: draft,
            visibleQueue: PickyVisibleQueue(
                queuedSteers: queuedSteers,
                queuedFollowUps: queuedFollowUps,
                committedUserMessages: []
            ),
            kind: .all
        )
    }

    static func editorHeight(forMeasuredContentHeight contentHeight: CGFloat) -> CGFloat {
        PickyComposerEditorHeightPolicy.height(forMeasuredContentHeight: contentHeight)
    }

    static func editorHeight(for text: String) -> CGFloat {
        PickyComposerEditorHeightPolicy.height(for: text)
    }

    static func autocompletePanelHeight(forSuggestionCount suggestionCount: Int) -> CGFloat {
        PickyComposerAutocompletePanelView.panelHeight(forSuggestionCount: suggestionCount)
    }

    func returnKeyAction(for modifiers: EventModifiers) -> PickyConversationComposerReturnKeyAction {
        Self.returnKeyAction(for: modifiers)
    }

    func upArrowKeyAction(for modifiers: EventModifiers) -> PickyConversationComposerUpArrowKeyAction {
        Self.upArrowKeyAction(for: modifiers)
    }
}
