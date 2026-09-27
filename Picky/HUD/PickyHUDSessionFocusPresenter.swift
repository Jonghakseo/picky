//
//  PickyHUDSessionFocusPresenter.swift
//  Picky
//
//  Display-scoped panel presentation, shared by HUD focus entry points.
//

import AppKit

@MainActor
protocol PickyHUDSessionFocusPanelPresenting: AnyObject {
    func prepareForSessionFocus()
    func orderFrontRegardless()
    func makeKey()
}

extension PickyHUDSessionFocusPanelPresenting {
    func prepareForSessionFocus() {}
}

extension PickyHUDPanel: PickyHUDSessionFocusPanelPresenting {
    func prepareForSessionFocus() { isDockMinimized = false }
}

@MainActor
enum PickyHUDSessionFocusPresenter {
    static func present<Panel: PickyHUDSessionFocusPanelPresenting>(
        targetDisplayID: CGDirectDisplayID?,
        panelsByDisplayID: [CGDirectDisplayID: Panel]
    ) {
        if let targetDisplayID, let panel = panelsByDisplayID[targetDisplayID] {
            panel.prepareForSessionFocus()
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        let orderedPanels = panelsByDisplayID.sorted { $0.key < $1.key }.map(\.value)
        orderedPanels.forEach {
            $0.prepareForSessionFocus()
            $0.orderFrontRegardless()
        }
        orderedPanels.first?.makeKey()
    }
}
