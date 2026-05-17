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

struct PickyIMETextView: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Binding<Bool>? = nil
    var isEditable: Bool = true
    var font: NSFont
    var textColor: NSColor
    var textContainerInsetHeight: CGFloat = 2
    var showsVerticalScroller: Bool = true
    var onMeasuredContentHeight: ((CGFloat) -> Void)?
    var onReturn: ((NSEvent.ModifierFlags) -> Bool)?
    var onUpArrow: ((NSEvent.ModifierFlags) -> Bool)?
    var onDownArrow: (() -> Bool)?
    var onTab: ((NSEvent.ModifierFlags) -> Bool)?
    var onEscape: (() -> Bool)?
    var onControlP: ((_ shiftPressed: Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: isFocused, onMeasuredContentHeight: onMeasuredContentHeight)
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
        context.coordinator.measure(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PickyIMENSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.isFocused = isFocused
        context.coordinator.onMeasuredContentHeight = onMeasuredContentHeight

        if PickyIMETextSynchronization.shouldOverwriteNativeText(
            nativeText: textView.string,
            bindingText: text,
            hasMarkedText: textView.hasMarkedText()
        ) {
            textView.string = text
        }

        configureCallbacks(on: textView, context: context)
        applyConfiguration(to: textView)

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
        textView.onReturn = onReturn
        textView.onUpArrow = onUpArrow
        textView.onDownArrow = onDownArrow
        textView.onTab = onTab
        textView.onEscape = onEscape
        textView.onControlP = onControlP
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
        var onMeasuredContentHeight: ((CGFloat) -> Void)?
        private var lastReportedContentHeight: CGFloat = 0

        init(text: Binding<String>, isFocused: Binding<Bool>?, onMeasuredContentHeight: ((CGFloat) -> Void)?) {
            self.text = text
            self.isFocused = isFocused
            self.onMeasuredContentHeight = onMeasuredContentHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            measure(textView: textView)
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
    var onReturn: ((NSEvent.ModifierFlags) -> Bool)?
    var onUpArrow: ((NSEvent.ModifierFlags) -> Bool)?
    var onDownArrow: (() -> Bool)?
    var onTab: ((NSEvent.ModifierFlags) -> Bool)?
    var onEscape: (() -> Bool)?
    var onControlP: ((_ shiftPressed: Bool) -> Void)?

    private var isCommittingMarkedTextWithReturn = false

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
