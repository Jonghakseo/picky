//
//  PickyIMETextView.swift
//  Picky
//
//  Shared IME-safe AppKit text editor for SwiftUI surfaces.
//

import AppKit
import SwiftUI

enum PickyIMETextSynchronization {
    static func shouldOverwriteNativeText(nativeText: String, bindingText: String, hasMarkedText: Bool) -> Bool {
        !hasMarkedText && nativeText != bindingText
    }
}

/// A coalesced native-editor snapshot. TextKit can notify text, selection, and
/// marked-text changes separately for one keystroke, so SwiftUI consumers use
/// this to publish one logical editor update on the next main-loop turn.
struct PickyIMETextInput: Equatable {
    let text: String
    let selection: NSRange
    let hasMarkedText: Bool
}

struct PickyIMETextView: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Binding<Bool>? = nil
    var isEditable: Bool = true
    var font: NSFont
    var textColor: NSColor
    var textContainerInsetHeight: CGFloat = 2
    var showsVerticalScroller: Bool = true
    var selectionOverride: Binding<NSRange?>? = nil
    var temporaryHighlightRange: NSRange? = nil
    var temporaryHighlightColor: NSColor? = nil
    var onSelectionChange: ((NSRange) -> Void)?
    var onMeasuredContentHeight: ((CGFloat) -> Void)?
    var onInputChange: ((PickyIMETextInput) -> Void)?
    var onMarkedTextChange: ((Bool) -> Void)?
    var onReturn: ((NSEvent.ModifierFlags) -> Bool)?
    var onUpArrow: ((NSEvent.ModifierFlags) -> Bool)?
    var onDownArrow: (() -> Bool)?
    var onTab: ((NSEvent.ModifierFlags) -> Bool)?
    var onEscape: (() -> Bool)?
    var onControlP: ((_ shiftPressed: Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: isFocused,
            onSelectionChange: onSelectionChange,
            onMeasuredContentHeight: onMeasuredContentHeight,
            onInputChange: onInputChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let textView = PickyIMENSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: textContainerInsetHeight)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        configureCallbacks(on: textView, context: context)
        scrollView.documentView = textView
        applyConfiguration(to: textView)
        applyTemporaryHighlight(to: textView)
        context.coordinator.measure(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PickyIMENSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.isFocused = isFocused
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onMeasuredContentHeight = onMeasuredContentHeight
        context.coordinator.onInputChange = onInputChange
        PickyPerf.event("ime_text_view_update")

        if PickyIMETextSynchronization.shouldOverwriteNativeText(
            nativeText: textView.string,
            bindingText: text,
            hasMarkedText: textView.hasMarkedText()
        ) {
            textView.string = text
        }

        if let selectionOverride, let override = selectionOverride.wrappedValue, !textView.hasMarkedText() {
            let textLength = textView.string.utf16.count
            let location = min(max(override.location, 0), textLength)
            let length = min(max(override.length, 0), textLength - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            DispatchQueue.main.async {
                selectionOverride.wrappedValue = nil
            }
        }

        configureCallbacks(on: textView, context: context)
        applyConfiguration(to: textView)
        applyTemporaryHighlight(to: textView)

        if isFocused?.wrappedValue == true, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        } else if isFocused?.wrappedValue == false, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
        context.coordinator.measure(textView: textView)
    }

    private func configureCallbacks(on textView: PickyIMENSTextView, context: Context) {
        textView.onFocusChange = { focused in
            context.coordinator.setFocused(focused)
        }
        textView.onLayout = { textView in
            context.coordinator.measure(textView: textView)
        }
        textView.onMarkedTextChange = onMarkedTextChange
        textView.onNativeInputStateChange = { [weak coordinator = context.coordinator] textView in
            coordinator?.scheduleInputChange(from: textView)
        }
        textView.onReturn = onReturn
        textView.onUpArrow = onUpArrow
        textView.onDownArrow = onDownArrow
        textView.onTab = onTab
        textView.onEscape = onEscape
        textView.onControlP = onControlP
    }

    private func applyTemporaryHighlight(to textView: PickyIMENSTextView) {
        textView.setTemporaryHighlight(
            range: temporaryHighlightRange,
            color: temporaryHighlightColor
        )
    }

    private func applyConfiguration(to textView: PickyIMENSTextView) {
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: textContainerInsetHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>?
        var onSelectionChange: ((NSRange) -> Void)?
        var onMeasuredContentHeight: ((CGFloat) -> Void)?
        var onInputChange: ((PickyIMETextInput) -> Void)?
        private var lastReportedContentHeight: CGFloat = 0
        private var inputChangeScheduled = false

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>?,
            onSelectionChange: ((NSRange) -> Void)?,
            onMeasuredContentHeight: ((CGFloat) -> Void)?,
            onInputChange: ((PickyIMETextInput) -> Void)?
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onSelectionChange = onSelectionChange
            self.onMeasuredContentHeight = onMeasuredContentHeight
            self.onInputChange = onInputChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            measure(textView: textView)
            scheduleInputChange(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if !textView.hasMarkedText(), let onSelectionChange {
                let selectedRange = textView.selectedRange()
                DispatchQueue.main.async {
                    onSelectionChange(selectedRange)
                }
            }
            scheduleInputChange(from: textView)
        }

        func scheduleInputChange(from textView: NSTextView) {
            guard !inputChangeScheduled else { return }
            inputChangeScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.inputChangeScheduled = false
                PickyPerf.event("ime_text_input_coalesced")
                self.onInputChange?(
                    PickyIMETextInput(
                        text: textView.string,
                        selection: textView.selectedRange(),
                        hasMarkedText: textView.hasMarkedText()
                    )
                )
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            setFocused(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            setFocused(false)
        }

        func setFocused(_ focused: Bool) {
            guard let isFocused, isFocused.wrappedValue != focused else { return }
            DispatchQueue.main.async {
                isFocused.wrappedValue = focused
            }
        }

        func measure(textView: NSTextView) {
            guard let onMeasuredContentHeight else { return }
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let contentHeight = usedHeight + textView.textContainerInset.height * 2
            guard abs(contentHeight - lastReportedContentHeight) > 0.5 else { return }
            lastReportedContentHeight = contentHeight
            DispatchQueue.main.async {
                onMeasuredContentHeight(contentHeight)
            }
        }
    }
}

final class PickyIMENSTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    var onLayout: ((PickyIMENSTextView) -> Void)?
    var onMarkedTextChange: ((Bool) -> Void)?
    var onNativeInputStateChange: ((PickyIMENSTextView) -> Void)?
    var onReturn: ((NSEvent.ModifierFlags) -> Bool)?
    var onUpArrow: ((NSEvent.ModifierFlags) -> Bool)?
    var onDownArrow: (() -> Bool)?
    var onTab: ((NSEvent.ModifierFlags) -> Bool)?
    var onEscape: (() -> Bool)?
    var onControlP: ((_ shiftPressed: Bool) -> Void)?

    private var isCommittingMarkedTextWithReturn = false
    private var temporaryHighlightRange: NSRange?
    private var lastReportedMarkedTextState = false

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }

    @discardableResult
    func focusForMouseDown() -> Bool {
        window?.makeKey()
        guard window?.firstResponder !== self else { return true }
        return window?.makeFirstResponder(self) == true
    }

    override func mouseDown(with event: NSEvent) {
        focusForMouseDown()
        super.mouseDown(with: event)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        clearTemporaryHighlight()
        reportMarkedTextState(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        reportMarkedTextState(false)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        reportMarkedTextState(hasMarkedText())
    }

    private func reportMarkedTextState(_ isMarked: Bool) {
        guard lastReportedMarkedTextState != isMarked else { return }
        lastReportedMarkedTextState = isMarked
        onMarkedTextChange?(isMarked)
        onNativeInputStateChange?(self)
    }

    func setTemporaryHighlight(range: NSRange?, color: NSColor?) {
        clearTemporaryHighlight()
        guard !hasMarkedText(), let range, range.length > 0, let color,
              range.location >= 0, NSMaxRange(range) <= string.utf16.count,
              let layoutManager else { return }
        layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
        temporaryHighlightRange = range
    }

    private func clearTemporaryHighlight() {
        guard let temporaryHighlightRange, let layoutManager else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: temporaryHighlightRange)
        self.temporaryHighlightRange = nil
    }

    override func layout() {
        super.layout()
        onLayout?(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout?(self)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == Self.returnKeyCode || event.keyCode == Self.keypadReturnKeyCode
        if hasMarkedText() {
            if isReturn { isCommittingMarkedTextWithReturn = true }
            let handledByInputContext = inputContext?.handleEvent(event) == true
            if isReturn { isCommittingMarkedTextWithReturn = false }
            if handledByInputContext { return }
        }

        if event.keyCode == Self.pKeyCode, event.modifierFlags.contains(.control) {
            onControlP?(event.modifierFlags.contains(.shift))
            return
        }

        switch event.keyCode {
        case Self.returnKeyCode, Self.keypadReturnKeyCode:
            if onReturn?(event.modifierFlags) == true { return }
        case Self.upArrowKeyCode:
            if onUpArrow?(event.modifierFlags) == true { return }
        case Self.downArrowKeyCode:
            if onDownArrow?() == true { return }
        case Self.tabKeyCode:
            if onTab?(event.modifierFlags) == true { return }
        case Self.escapeKeyCode:
            if onEscape?() == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if isCommittingMarkedTextWithReturn { return }
        super.insertNewline(sender)
    }

    static let returnKeyCode: UInt16 = 36
    static let keypadReturnKeyCode: UInt16 = 76
    static let tabKeyCode: UInt16 = 48
    static let escapeKeyCode: UInt16 = 53
    static let upArrowKeyCode: UInt16 = 126
    static let downArrowKeyCode: UInt16 = 125
    static let pKeyCode: UInt16 = 35
}
