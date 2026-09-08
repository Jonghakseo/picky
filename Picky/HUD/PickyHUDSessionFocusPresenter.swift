//
//  PickyHUDSessionFocusPresenter.swift
//  Picky
//
//  Display-scoped panel presentation, shared by HUD focus entry points.
//

import AppKit

@MainActor
protocol PickyHUDSessionFocusPanelPresenting: AnyObject {
    func orderFrontRegardless()
    func makeKey()
}

extension PickyHUDPanel: PickyHUDSessionFocusPanelPresenting {}

@MainActor
enum PickyHUDSessionFocusPresenter {
    static func present<Panel: PickyHUDSessionFocusPanelPresenting>(
        targetDisplayID: CGDirectDisplayID?,
        panelsByDisplayID: [CGDirectDisplayID: Panel]
    ) {
        if let targetDisplayID, let panel = panelsByDisplayID[targetDisplayID] {
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        let orderedPanels = panelsByDisplayID.sorted { $0.key < $1.key }.map(\.value)
        orderedPanels.forEach { $0.orderFrontRegardless() }
        orderedPanels.first?.makeKey()
    }
}
