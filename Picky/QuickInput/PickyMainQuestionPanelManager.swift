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
}

struct PickyMainQuestionPanelAnswerError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class PickyMainQuestionKeyablePanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}

enum PickyMainQuestionPanelLayout {
    static let contentWidth: CGFloat = 360
    static let shadowOutset: CGFloat = 10
    static let panelWidth: CGFloat = contentWidth + shadowOutset * 2
    static let estimatedPanelHeight: CGFloat = 360
    static let cursorOffsetX: CGFloat = 18
    static let cursorOffsetY: CGFloat = 12
    static let maximumScreenHeightFraction: CGFloat = 0.7

    static func cappedHeight(fittingHeight: CGFloat, visibleScreenHeight: CGFloat?) -> CGFloat {
        let desiredHeight = max(fittingHeight, estimatedPanelHeight)
        guard let visibleScreenHeight else { return desiredHeight }
        return min(desiredHeight, visibleScreenHeight * maximumScreenHeightFraction)
    }
}

@MainActor
final class PickyMainQuestionPanelManager {
    private let viewModel = PickyMainQuestionPanelViewModel()
    private let appearanceStore: PickyAppearanceStore
    private let fontScaleStore: PickyAppFontScaleStore
    private var panel: PickyMainQuestionKeyablePanel?

    /// Returns nil when agentd accepted the answer, otherwise keeps the panel
    /// open and logs the transport failure for diagnosis.
    var onAnswer: (String, JSONValue) async -> Error? = { _, _ in nil }

    init(
        appearanceStore: PickyAppearanceStore? = nil,
        fontScaleStore: PickyAppFontScaleStore? = nil
    ) {
        self.appearanceStore = appearanceStore ?? PickyAppearanceStore()
        self.fontScaleStore = fontScaleStore ?? PickyAppFontScaleStore()
        viewModel.onAnswer = { [weak self] requestID, value in
            self?.sendAnswer(requestID: requestID, value: value)
        }
    }

    func update(request: PickyExtensionUiRequest?) {
        guard PickyMainQuestionPanelPolicy.shouldPresent(request: request), let request else {
            dismiss()
            return
        }
        if panel == nil { createPanel() }
        viewModel.configure(request: request)
        positionPanelNearCursor(NSEvent.mouseLocation)
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error = await self.onAnswer(requestID, value) {
                print("⚠️ Failed to answer main extension UI request \(requestID): \(error.localizedDescription)")
                self.viewModel.isSending = false
                return
            }
            self.dismiss()
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
        questionPanel.level = .pickyCursorOverlay
        questionPanel.isOpaque = false
        questionPanel.backgroundColor = .clear
        questionPanel.hasShadow = false
        questionPanel.hidesOnDeactivate = false
        questionPanel.isExcludedFromWindowsMenu = true
        questionPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        questionPanel.isMovableByWindowBackground = false
        questionPanel.titleVisibility = .hidden
        questionPanel.titlebarAppearsTransparent = true
        questionPanel.sharingType = .none
        questionPanel.contentView = hostingView
        questionPanel.onEscape = { [weak viewModel] in viewModel?.cancel() }
        panel = questionPanel
    }

    private func positionPanelNearCursor(_ cursorLocation: CGPoint) {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorLocation) }) ?? NSScreen.main
        let fittingSize = panel.contentView?.fittingSize
            ?? CGSize(width: PickyMainQuestionPanelLayout.panelWidth, height: PickyMainQuestionPanelLayout.estimatedPanelHeight)
        let panelSize = CGSize(
            width: PickyMainQuestionPanelLayout.panelWidth,
            height: PickyMainQuestionPanelLayout.cappedHeight(
                fittingHeight: fittingSize.height,
                visibleScreenHeight: screen?.visibleFrame.height
            )
        )
        var originX = cursorLocation.x + PickyMainQuestionPanelLayout.cursorOffsetX - PickyMainQuestionPanelLayout.shadowOutset
        var originY = cursorLocation.y - PickyMainQuestionPanelLayout.cursorOffsetY - (panelSize.height - PickyMainQuestionPanelLayout.shadowOutset)

        if let screen {
            let visibleFrame = screen.visibleFrame
            if originX + panelSize.width > visibleFrame.maxX {
                originX = cursorLocation.x - PickyMainQuestionPanelLayout.cursorOffsetX - panelSize.width + PickyMainQuestionPanelLayout.shadowOutset
            }
            if originY < visibleFrame.minY {
                originY = cursorLocation.y + PickyMainQuestionPanelLayout.cursorOffsetY - PickyMainQuestionPanelLayout.shadowOutset
            }
            originX = max(visibleFrame.minX, min(originX, visibleFrame.maxX - panelSize.width))
            originY = max(visibleFrame.minY, min(originY, visibleFrame.maxY - panelSize.height))
        }

        panel.setFrame(NSRect(origin: CGPoint(x: originX, y: originY), size: panelSize), display: true)
    }

    #if DEBUG
    var viewModelForTesting: PickyMainQuestionPanelViewModel { viewModel }
    #endif
}
