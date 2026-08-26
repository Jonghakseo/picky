//
//  PickyIMETextViewTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyIMETextViewTests {
    @Test func bindingSyncPreservesNativeMarkedText() throws {
        #expect(PickyIMETextSynchronization.shouldOverwriteNativeText(
            nativeText: "ㅎ",
            bindingText: "",
            hasMarkedText: true
        ) == false)
        #expect(PickyIMETextSynchronization.shouldOverwriteNativeText(
            nativeText: "한글",
            bindingText: "한글",
            hasMarkedText: false
        ) == false)
        #expect(PickyIMETextSynchronization.shouldOverwriteNativeText(
            nativeText: "old",
            bindingText: "new",
            hasMarkedText: false
        ) == true)
    }

    @Test func editorsKeepUndoHistoriesIndependentInsideTheSameWindow() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let first = PickyIMENSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        let second = PickyIMENSTextView(frame: NSRect(x: 160, y: 0, width: 160, height: 120))
        first.allowsUndo = true
        second.allowsUndo = true
        panel.contentView?.addSubview(first)
        panel.contentView?.addSubview(second)
        defer { panel.close() }

        panel.makeFirstResponder(first)
        first.insertText("first", replacementRange: NSRange(location: 0, length: 0))
        panel.makeFirstResponder(second)
        second.insertText("second", replacementRange: NSRange(location: 0, length: 0))

        #expect(first.undoManager !== second.undoManager)
        first.undoManager?.undo()
        #expect(first.string.isEmpty)
        #expect(second.string == "second")
    }

    @Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))
    func responderActionsUndoAndRedoTheFocusedEditorsPrivateHistory() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let textView = PickyIMENSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        textView.allowsUndo = true
        panel.contentView = textView
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        defer { panel.close() }

        textView.insertText("draft", replacementRange: NSRange(location: 0, length: 0))

        #expect(NSApp.sendAction(Selector(("undo:")), to: nil, from: nil))
        #expect(textView.string.isEmpty)
        #expect(NSApp.sendAction(Selector(("redo:")), to: nil, from: nil))
        #expect(textView.string == "draft")
    }

    @Test func bindingReplacementDropsNativeUndoOperations() throws {
        let textView = PickyIMENSTextView()
        textView.allowsUndo = true
        textView.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
        #expect(textView.undoManager?.canUndo == true)

        textView.replaceTextFromBinding("")

        #expect(textView.string.isEmpty)
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test func removalDropsNativeUndoOperationsAndEditorCallbacks() throws {
        let textView = PickyIMENSTextView()
        textView.allowsUndo = true
        textView.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
        textView.onReturn = { _ in true }
        #expect(textView.undoManager?.canUndo == true)

        textView.prepareForRemoval()

        #expect(textView.allowsUndo == false)
        #expect(textView.undoManager == nil)
        #expect(textView.onReturn == nil)
    }

    @Test func returnCommitsThroughSubmitHandlerWithoutInsertingNewline() throws {
        let textView = PickyIMENSTextView()
        textView.string = "ready"
        var submittedModifiers: NSEvent.ModifierFlags?
        textView.onReturn = { modifiers in
            submittedModifiers = modifiers
            return true
        }

        textView.keyDown(with: Self.returnKeyEvent())

        #expect(submittedModifiers != nil)
        #expect(textView.string == "ready")
    }

    @Test func shiftReturnFallsThroughToNativeNewlineInsertion() throws {
        let textView = PickyIMENSTextView()
        textView.string = "first"
        textView.selectedRange = NSRange(location: textView.string.count, length: 0)
        textView.onReturn = { modifiers in
            modifiers.contains(.shift) ? false : true
        }

        textView.keyDown(with: Self.returnKeyEvent(modifiers: .shift))

        #expect(textView.string == "first\n")
    }

    @Test func temporaryHighlightStylesTextWithoutMutatingEditorContent() throws {
        let textView = PickyIMENSTextView()
        textView.string = ">worker task"
        let range = NSRange(location: 0, length: 7)

        textView.setTemporaryHighlight(range: range, color: .systemBlue)

        #expect(textView.string == ">worker task")
        let temporaryColor = textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 1,
            effectiveRange: nil
        ) as? NSColor
        #expect(temporaryColor == .systemBlue)

        textView.setTemporaryHighlight(range: nil, color: nil)
        #expect(textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 1,
            effectiveRange: nil
        ) == nil)
    }

    @Test func markedTextClearsTemporaryHighlightAndReportsCompositionState() throws {
        let textView = PickyIMENSTextView()
        textView.string = ">w"
        textView.setTemporaryHighlight(range: NSRange(location: 0, length: 2), color: .systemBlue)
        var states: [Bool] = []
        textView.onMarkedTextChange = { states.append($0) }

        textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(states == [true])
        #expect(textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 1,
            effectiveRange: nil
        ) == nil)

        textView.unmarkText()
        #expect(states == [true, false])
    }

    @Test func insertTextCommitReportsMarkedTextEndedWithoutExplicitUnmark() throws {
        let textView = PickyIMENSTextView()
        var states: [Bool] = []
        textView.onMarkedTextChange = { states.append($0) }

        textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        textView.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(states == [true, false])
        #expect(!textView.hasMarkedText())
    }

    @Test func mouseDownFocusHelperMakesTextViewFirstResponderInNonactivatingHUDPanel() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let textView = PickyIMENSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        panel.contentView = textView
        defer { panel.close() }

        #expect(panel.firstResponder !== textView)

        #expect(textView.focusForMouseDown())

        #expect(panel.firstResponder === textView)
    }

    @Test func hudPanelRestoresComposerOnlyAfterItBecomesFirstResponder() throws {
        let panel = Self.makeHUDPanel()
        let composer = PickyIMENSTextView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = composer
        defer { panel.close() }

        #expect(!panel.restoreRememberedNativeInputResponderIfNeeded())
        #expect(panel.makeFirstResponder(composer))
        #expect(panel.makeFirstResponder(nil))

        #expect(panel.restoreRememberedNativeInputResponderIfNeeded())
        #expect(panel.firstResponder === composer)
    }

    @Test func hudPanelSendEventRestoresComposerAndDeliversCharacter() throws {
        let panel = Self.makeHUDPanel()
        let composer = PickyIMENSTextView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = composer
        defer { panel.close() }

        #expect(panel.makeFirstResponder(composer))
        #expect(panel.makeFirstResponder(nil))
        let event = try #require(Self.characterKeyEvent("x", keyCode: 7, windowNumber: panel.windowNumber))

        panel.sendEvent(event)

        #expect(panel.firstResponder === composer)
        #expect(composer.string == "x")
    }

    @Test func hudPanelsKeepRememberedNativeInputRespondersIndependent() throws {
        let firstPanel = Self.makeHUDPanel()
        let secondPanel = Self.makeHUDPanel()
        let firstComposer = PickyIMENSTextView(frame: firstPanel.contentView?.bounds ?? .zero)
        let secondComposer = PickyIMENSTextView(frame: secondPanel.contentView?.bounds ?? .zero)
        firstPanel.contentView = firstComposer
        secondPanel.contentView = secondComposer
        defer {
            firstPanel.close()
            secondPanel.close()
        }

        #expect(firstPanel.makeFirstResponder(firstComposer))
        #expect(secondPanel.makeFirstResponder(secondComposer))
        #expect(firstPanel.makeFirstResponder(nil))
        #expect(secondPanel.makeFirstResponder(nil))

        #expect(firstPanel.restoreRememberedNativeInputResponderIfNeeded())
        #expect(secondPanel.restoreRememberedNativeInputResponderIfNeeded())
        #expect(firstPanel.firstResponder === firstComposer)
        #expect(secondPanel.firstResponder === secondComposer)
    }

    @Test func hudPanelRejectsRememberedInputDetachedFromItsPanel() throws {
        let panel = Self.makeHUDPanel()
        let otherPanel = Self.makeHUDPanel()
        let composer = PickyIMENSTextView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = composer
        defer {
            panel.close()
            otherPanel.close()
        }

        #expect(panel.makeFirstResponder(composer))
        #expect(panel.makeFirstResponder(nil))
        otherPanel.contentView = composer

        #expect(!panel.restoreRememberedNativeInputResponderIfNeeded())
        #expect(panel.firstResponder !== composer)
    }

    @Test func hudPanelPreservesAnotherIntentionalFirstResponder() throws {
        let panel = Self.makeHUDPanel()
        let contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
        let composer = PickyIMENSTextView(frame: contentView.bounds)
        let titleEditor = NSTextView(frame: contentView.bounds)
        contentView.addSubview(composer)
        contentView.addSubview(titleEditor)
        panel.contentView = contentView
        defer { panel.close() }

        #expect(panel.makeFirstResponder(composer))
        #expect(panel.makeFirstResponder(titleEditor))

        #expect(!panel.restoreRememberedNativeInputResponderIfNeeded())
        #expect(panel.firstResponder === titleEditor)
    }

    @Test func hudPanelDoesNotRestoreWhenContentViewIsFirstResponder() throws {
        let panel = Self.makeHUDPanel()
        let contentView = PickyFirstResponderContentView(frame: panel.contentView?.bounds ?? .zero)
        let composer = PickyIMENSTextView(frame: contentView.bounds)
        contentView.addSubview(composer)
        panel.contentView = contentView
        defer { panel.close() }

        #expect(panel.makeFirstResponder(composer))
        #expect(panel.makeFirstResponder(contentView))

        #expect(!panel.restoreRememberedNativeInputResponderIfNeeded())
        #expect(panel.firstResponder === contentView)
    }

    @Test func hudPanelIntentionalBlurPreventsSubsequentKeyEventRestore() throws {
        let panel = Self.makeHUDPanel()
        let composer = PickyIMENSTextView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = composer
        defer { panel.close() }

        #expect(panel.makeFirstResponder(composer))
        #expect(panel.resignFocusedControl())
        let event = try #require(Self.characterKeyEvent("x", keyCode: 7, windowNumber: panel.windowNumber))

        panel.sendEvent(event)

        #expect(panel.firstResponder !== composer)
        #expect(composer.string.isEmpty)
    }

    @Test func hudPanelIntentionalBlurClearsRememberedInputFromPanelFallback() throws {
        let panel = Self.makeHUDPanel()
        let composer = PickyIMENSTextView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = composer
        defer { panel.close() }

        #expect(panel.makeFirstResponder(composer))
        #expect(panel.makeFirstResponder(nil))
        #expect(panel.firstResponder === panel)
        #expect(panel.resignFocusedControl())

        #expect(!panel.restoreRememberedNativeInputResponderIfNeeded())
    }

    @Test func hudPanelRestoresTerminalAfterItBecomesFirstResponder() throws {
        let panel = Self.makeHUDPanel()
        let terminal = PickySwiftTermView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = terminal
        defer { panel.close() }

        #expect(panel.makeFirstResponder(terminal))
        #expect(panel.makeFirstResponder(nil))

        #expect(panel.restoreRememberedNativeInputResponderIfNeeded())
        #expect(panel.firstResponder === terminal)
    }

    private static func makeHUDPanel() -> PickyHUDPanel {
        PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private static func characterKeyEvent(
        _ characters: String,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private static func returnKeyEvent(modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: PickyIMENSTextView.returnKeyCode
        )!
    }
}

private final class PickyFirstResponderContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
