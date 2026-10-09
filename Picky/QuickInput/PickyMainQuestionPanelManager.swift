//
//  PickyMainQuestionPanelManager.swift
//  Picky
//
//  Floating main-agent askUserQuestion panel lifecycle.
//

import AppKit
import SwiftUI

enum PickyMainQuestionPanelPolicy {
    static let cancellationValue: JSONValue = .object(["cancelled": .bool(true)])

    static func shouldPresent(request: PickyExtensionUiRequest?) -> Bool {
        request != nil
    }

    static func shouldClearPendingQuestion(after answerError: PickyErrorEvent?) -> Bool {
        answerError == nil
    }

    static func shouldReopenAfterAnswerFailure(
        requestID: String,
        activeRequestID: String?,
        error: Error?
    ) -> Bool {
        error != nil && requestID == activeRequestID
    }

    /// Esc dismisses the panel only when it is not needed to discard native IME composition.
    static func shouldCancelOnEscape(firstResponderHasMarkedText: Bool) -> Bool {
        !firstResponderHasMarkedText
    }

    /// Bare 1-9 picks an option unless a text field is taking the keystroke.
    static func optionNumber(characters: String?, modifiers: NSEvent.ModifierFlags, firstResponderIsEditingText: Bool) -> Int? {
        guard !firstResponderIsEditingText,
              modifiers.intersection([.command, .control, .option]).isEmpty,
              let characters, characters.count == 1,
              let number = Int(characters), (1...9).contains(number)
        else { return nil }
        return number
    }
}

struct PickyMainQuestionPanelAnswerError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class PickyMainQuestionKeyablePanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow {
    var onEscape: (() -> Void)?
    var onOptionNumber: ((Int) -> Void)?
    var onReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 53,
           PickyMainQuestionPanelPolicy.shouldCancelOnEscape(
               firstResponderHasMarkedText: (firstResponder as? NSTextView)?.hasMarkedText() == true
           ) {
            onEscape?()
            return
        }
        if event.type == .keyDown {
            // A focused text field owns its own digits and Return (its onSubmit advances).
            let editingText = firstResponder is NSTextView
            if let number = PickyMainQuestionPanelPolicy.optionNumber(
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags,
                firstResponderIsEditingText: editingText
            ), let onOptionNumber {
                onOptionNumber(number)
                return
            }
            if !editingText, event.keyCode == 36 || event.keyCode == 76,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               let onReturn {
                onReturn()
                return
            }
        }
        super.sendEvent(event)
    }
}

enum PickyMainQuestionPanelLayout {
    static let contentWidth: CGFloat = 360
    static let shadowOutset: CGFloat = 10
    static let panelWidth: CGFloat = contentWidth + shadowOutset * 2
    /// First-frame height before SwiftUI reports the measured content height.
    static let estimatedPanelHeight: CGFloat = 220
    /// Leaves room for the grabber, header and footer within 0.7 of an 800pt screen.
    static let maximumScrollableContentHeight: CGFloat = 420
    static let maximumScreenHeightFraction: CGFloat = 0.7
    /// Full-width grab strip above the header; the capsule is centered in it.
    static let dragStripHeight: CGFloat = 20

    /// The form scrolls only past the cap; below it the panel shows every row.
    static func scrollViewHeight(contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, 1), maximumScrollableContentHeight)
    }

    /// Centers the panel's visible card on the screen. The shadow outset is
    /// symmetric, so centering the window frame centers the card too.
    static func centeredFrame(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
    }

    static func cappedHeight(fittingHeight: CGFloat, visibleScreenHeight: CGFloat?) -> CGFloat {
        guard let visibleScreenHeight else { return fittingHeight }
        return min(fittingHeight, visibleScreenHeight * maximumScreenHeightFraction)
    }
}

@MainActor
final class PickyMainQuestionPanelManager {
    private let viewModel = PickyMainQuestionPanelViewModel()
    private let appearanceStore: PickyAppearanceStore
    private let fontScaleStore: PickyAppFontScaleStore
    private var panel: PickyMainQuestionKeyablePanel?
    /// Set once the user drags the panel, so a later answer-failure reopen keeps
    /// their chosen spot instead of snapping back to the cursor. Reset per request.
    private var hasUserMovedPanel = false
    private var lastContentHeight: CGFloat?
    private var isProgrammaticMove = false
    private var panelMoveObserver: NSObjectProtocol?

    /// Returns nil when agentd accepted the answer, otherwise keeps the panel
    /// open and logs the transport failure for diagnosis.
    var onAnswer: (String, JSONValue) async -> Error? = { _, _ in nil }

    /// True while this panel visibly owns keyboard input (and therefore ESC as
    /// its cancel key). A hidden panel that lingers as key window does not count.
    var visiblyOwnsKeyWindow: Bool { panel?.isKeyWindow == true && panel?.isVisible == true }

    init(
        appearanceStore: PickyAppearanceStore? = nil,
        fontScaleStore: PickyAppFontScaleStore? = nil
    ) {
        self.appearanceStore = appearanceStore ?? PickyAppearanceStore()
        self.fontScaleStore = fontScaleStore ?? PickyAppFontScaleStore()
        viewModel.onAnswer = { [weak self] requestID, value in
            self?.sendAnswer(requestID: requestID, value: value)
        }
        viewModel.onContentHeightChange = { [weak self] height in
            self?.resizePanel(toContentHeight: height)
        }
    }

    deinit {
        if let panelMoveObserver {
            NotificationCenter.default.removeObserver(panelMoveObserver)
        }
    }

    func update(request: PickyExtensionUiRequest?) {
        guard PickyMainQuestionPanelPolicy.shouldPresent(request: request), let request else {
            dismiss()
            return
        }
        let isNewRequest = viewModel.request?.id != request.id
        if panel == nil { createPanel() }
        viewModel.configure(request: request)
        if isNewRequest {
            hasUserMovedPanel = false
            positionPanelCentered(on: NSEvent.mouseLocation)
        }
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func dismiss() {
        viewModel.clear()
        panel?.orderOut(nil)
    }

    private func sendAnswer(requestID: String, value: JSONValue) {
        guard !viewModel.isSending else { return }
        viewModel.isSending = true
        viewModel.errorMessage = nil
        panel?.orderOut(nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let error = await self.onAnswer(requestID, value)
            guard PickyMainQuestionPanelPolicy.shouldReopenAfterAnswerFailure(
                requestID: requestID,
                activeRequestID: self.viewModel.request?.id,
                error: error
            ) else {
                return
            }

            let message = error?.localizedDescription ?? L10n.t("hud.question.sendFailed")
            print("⚠️ Failed to answer main extension UI request \(requestID): \(message)")
            self.viewModel.isSending = false
            self.viewModel.errorMessage = message
            if !self.hasUserMovedPanel {
                self.positionPanelCentered(on: NSEvent.mouseLocation)
            }
            self.panel?.makeKeyAndOrderFront(nil)
            self.panel?.orderFrontRegardless()
        }
    }

    private func createPanel() {
        let questionView = PickyMainQuestionPanelView(viewModel: viewModel)
            .environmentObject(appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))
        let rootView = PickyAppFontScaleRoot(store: fontScaleStore) { questionView }
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { rootView })
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: PickyMainQuestionPanelLayout.panelWidth,
            height: PickyMainQuestionPanelLayout.estimatedPanelHeight
        )

        let questionPanel = PickyMainQuestionKeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        questionPanel.isFloatingPanel = true
        questionPanel.level = NSWindow.Level(rawValue: NSWindow.Level.pickyCursorOverlay.rawValue - 1)
        questionPanel.isOpaque = false
        questionPanel.backgroundColor = .clear
        questionPanel.hasShadow = false
        questionPanel.hidesOnDeactivate = false
        questionPanel.isExcludedFromWindowsMenu = true
        questionPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        questionPanel.isMovableByWindowBackground = true
        questionPanel.titleVisibility = .hidden
        questionPanel.titlebarAppearsTransparent = true
        questionPanel.sharingType = .none
        questionPanel.contentView = hostingView
        questionPanel.onEscape = { [weak viewModel] in viewModel?.cancel() }
        questionPanel.onOptionNumber = { [weak viewModel] number in viewModel?.applyNumberKey(number) }
        questionPanel.onReturn = { [weak viewModel] in viewModel?.performPrimary() }
        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: questionPanel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isProgrammaticMove else { return }
                self.hasUserMovedPanel = true
            }
        }
        panel = questionPanel
    }

    /// SwiftUI measures the form after `configure`, so the first placement uses
    /// the last known height and this call corrects it. The panel stays centered
    /// until the user drags it; after that the top edge stays put.
    private func resizePanel(toContentHeight contentHeight: CGFloat) {
        // A cleared panel measures as bare padding; keep the last real form height.
        guard let panel, contentHeight > 0, viewModel.request != nil else { return }
        lastContentHeight = contentHeight
        let screen = panel.screen ?? NSScreen.main
        let height = PickyMainQuestionPanelLayout.cappedHeight(
            fittingHeight: contentHeight,
            visibleScreenHeight: screen?.visibleFrame.height
        )
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        if !hasUserMovedPanel, let visibleFrame = screen?.visibleFrame {
            frame = PickyMainQuestionPanelLayout.centeredFrame(
                size: CGSize(width: frame.width, height: height),
                in: visibleFrame
            )
        } else {
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            if let visibleFrame = screen?.visibleFrame, frame.minY < visibleFrame.minY {
                frame.origin.y = visibleFrame.minY
            }
        }
        isProgrammaticMove = true
        panel.setFrame(frame, display: true)
        isProgrammaticMove = false
    }

    /// Opens on the screen the user is working on (the one under the cursor),
    /// centered rather than beside the cursor, since a question needs attention.
    private func positionPanelCentered(on cursorLocation: CGPoint) {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorLocation) }) ?? NSScreen.main
        let panelSize = CGSize(
            width: PickyMainQuestionPanelLayout.panelWidth,
            height: PickyMainQuestionPanelLayout.cappedHeight(
                fittingHeight: lastContentHeight ?? PickyMainQuestionPanelLayout.estimatedPanelHeight,
                visibleScreenHeight: screen?.visibleFrame.height
            )
        )
        let frame = screen.map { PickyMainQuestionPanelLayout.centeredFrame(size: panelSize, in: $0.visibleFrame) }
            ?? CGRect(origin: panel.frame.origin, size: panelSize)

        isProgrammaticMove = true
        panel.setFrame(frame, display: true)
        isProgrammaticMove = false
    }

    #if DEBUG
    var viewModelForTesting: PickyMainQuestionPanelViewModel { viewModel }
    #endif
}
