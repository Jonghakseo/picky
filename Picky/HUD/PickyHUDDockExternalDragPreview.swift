//
//  PickyHUDDockExternalDragPreview.swift
//  Picky
//
//  Detached drag image and pure terminal presentation policy for an external
//  Dock drag. The panel is deliberately input-transparent: the coordinator
//  remains the sole owner of pointer lifetime.
//

import AppKit
import Combine
import SwiftUI

struct PickyHUDDockExternalDragPreviewPresentation {
    let token: UUID
    let sourceGroupID: String
    let session: PickyHUDDockSession
    let sourceFrame: CGRect
    let pointerScreenPoint: CGPoint
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics

    init(
        token: UUID = UUID(),
        sourceGroupID: String = "",
        session: PickyHUDDockSession,
        sourceFrame: CGRect,
        pointerScreenPoint: CGPoint,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics
    ) {
        self.token = token
        self.sourceGroupID = sourceGroupID
        self.session = session
        self.sourceFrame = sourceFrame
        self.pointerScreenPoint = pointerScreenPoint
        self.dockSide = dockSide
        self.metrics = metrics
    }
}

enum PickyHUDDockExternalDragPreviewTerminal: Equatable {
    case dismiss
    case returnToSource(CGPoint)
    case fadeOut
}

enum PickyHUDDockExternalDragPreviewPresentationPolicy {
    static func frame(
        pointerScreenPoint: CGPoint,
        metrics: PickyHUDDockMetrics
    ) -> CGRect {
        CGRect(
            x: pointerScreenPoint.x - (metrics.sessionTileWidth / 2),
            y: pointerScreenPoint.y - (metrics.sessionTileHeight / 2),
            width: metrics.sessionTileWidth,
            height: metrics.sessionTileHeight
        )
    }

    static func sourceFrameIsUsable(_ sourceFrame: CGRect) -> Bool {
        sourceFrame.isFinite && sourceFrame.width > 0 && sourceFrame.height > 0
    }

    static func terminal(
        terminal: PickyHUDDockExternalDragTerminal,
        sourceFrame: CGRect,
        reduceMotion: Bool,
        sourceIsUsable: Bool
    ) -> PickyHUDDockExternalDragPreviewTerminal {
        switch terminal {
        case .commit:
            return .dismiss
        case .cancel(.teardown), .cancel(.staleLayout):
            // Teardown and stale geometry must never animate toward a surface
            // that has moved or is already hidden.
            return reduceMotion ? .dismiss : .fadeOut
        case .cancel(.escape), .cancel(.invalidDrop):
            guard !reduceMotion else { return .dismiss }
            guard sourceIsUsable, sourceFrameIsUsable(sourceFrame) else { return .fadeOut }
            return .returnToSource(CGPoint(x: sourceFrame.midX, y: sourceFrame.midY))
        }
    }
}

/// Old animation completions may run after a new physical drag has opened a
/// replacement preview. Only the current token may close the driver state.
enum PickyHUDDockExternalDragPreviewGenerationPolicy {
    static func mayClose(activeToken: UUID?, finishingToken: UUID) -> Bool {
        activeToken == finishingToken
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}

@MainActor
protocol PickyHUDDockExternalDragPreviewDriving: AnyObject {
    func begin(_ presentation: PickyHUDDockExternalDragPreviewPresentation)
    func update(pointerScreenPoint: CGPoint, destination: PickyDockContainer?)
    func finish(terminal: PickyHUDDockExternalDragTerminal)
}

/// Separate panel prevents a drag image from clipping between the HUD and its
/// child group-list panel. It never becomes key or receives mouse events.
final class PickyHUDDockExternalDragPreviewPanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: bufferingType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}

@MainActor
private final class PickyHUDDockExternalDragPreviewModel: ObservableObject {
    let presentation: PickyHUDDockExternalDragPreviewPresentation
    @Published var destination: PickyDockContainer?

    init(presentation: PickyHUDDockExternalDragPreviewPresentation) {
        self.presentation = presentation
    }
}

private struct PickyHUDDockExternalDragPreviewView: View {
    @ObservedObject var model: PickyHUDDockExternalDragPreviewModel

    private var isAccepted: Bool { model.destination != nil }

    var body: some View {
        PickyHUDDockIconView(
            session: model.presentation.session,
            index: 0,
            isActive: false,
            isOpened: false,
            isPreviewed: false,
            isScreenContextArmed: false,
            isScreenContextSticky: false,
            dockSide: model.presentation.dockSide,
            shortcutNumber: nil,
            isCommandShortcutHintVisible: false,
            shouldFlashCompletion: false,
            isUnread: false,
            metrics: model.presentation.metrics,
            isDragging: true,
            dragOffset: .zero,
            onHover: {},
            onOpen: {},
            onToggleScreenContextTarget: {},
            onToggleStickyScreenContextTarget: {},
            onCompact: {},
            onArchive: {},
            onStop: {},
            onDoneFlashConsumed: {},
            onReorderHandoff: { _ in }
        )
        .overlay(alignment: .topTrailing) {
            if !isAccepted {
                Image(systemName: "circle.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Colors.textOnAccent)
                    .padding(DS.Spacing.space1)
                    .background(DS.Colors.destructive, in: Circle())
            }
        }
        .opacity(isAccepted ? 1 : 0.72)
        .accessibilityHidden(true)
    }
}

/// AppKit owner for one preview panel. Unit tests use the policy above instead
/// of asserting WindowServer ordering or animation callbacks.
@MainActor
final class PickyHUDDockExternalDragPreviewDriver: PickyHUDDockExternalDragPreviewDriving {
    private var panel: PickyHUDDockExternalDragPreviewPanel?
    private var model: PickyHUDDockExternalDragPreviewModel?
    private let presentationStore: PickyHUDDockExternalDragRailPresentationStore
    private var sourceIsUsable: (PickyHUDDockExternalDragPreviewPresentation) -> Bool
    private var reduceMotion: () -> Bool

    init(
        presentationStore: PickyHUDDockExternalDragRailPresentationStore,
        sourceIsUsable: @escaping (PickyHUDDockExternalDragPreviewPresentation) -> Bool = { _ in true },
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.presentationStore = presentationStore
        self.sourceIsUsable = sourceIsUsable
        self.reduceMotion = reduceMotion
    }

    func begin(_ presentation: PickyHUDDockExternalDragPreviewPresentation) {
        closeImmediately()
        let model = PickyHUDDockExternalDragPreviewModel(presentation: presentation)
        let panel = PickyHUDDockExternalDragPreviewPanel(
            contentRect: PickyHUDDockExternalDragPreviewPresentationPolicy.frame(
                pointerScreenPoint: presentation.pointerScreenPoint,
                metrics: presentation.metrics
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: 20)
        panel.contentView = NSHostingView(rootView: PickyHUDDockExternalDragPreviewView(model: model))
        panel.orderFrontRegardless()
        self.model = model
        self.panel = panel
        presentationStore.show(
            token: presentation.token,
            sessionID: presentation.session.id,
            destination: nil
        )
    }

    func update(pointerScreenPoint: CGPoint, destination: PickyDockContainer?) {
        guard let panel, let model else { return }
        model.destination = destination
        presentationStore.update(token: model.presentation.token, destination: destination)
        panel.setFrame(
            PickyHUDDockExternalDragPreviewPresentationPolicy.frame(
                pointerScreenPoint: pointerScreenPoint,
                metrics: model.presentation.metrics
            ),
            display: true
        )
    }

    func finish(terminal: PickyHUDDockExternalDragTerminal) {
        guard let panel, let model else { return }
        let finishingToken = model.presentation.token
        presentationStore.clear(token: finishingToken)
        let presentationTerminal = PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            terminal: terminal,
            sourceFrame: model.presentation.sourceFrame,
            reduceMotion: reduceMotion(),
            sourceIsUsable: sourceIsUsable(model.presentation)
        )
        switch presentationTerminal {
        case .dismiss:
            closeImmediately(token: finishingToken)
        case .returnToSource(let center):
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Animation.fast
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(
                    PickyHUDDockExternalDragPreviewPresentationPolicy.frame(
                        pointerScreenPoint: center,
                        metrics: model.presentation.metrics
                    ),
                    display: true
                )
            } completionHandler: { [weak self, finishingPanel = panel] in
                // Manager teardown can release the driver before this closure
                // runs. Retaining only the finishing panel keeps the AppKit
                // surface alive long enough to order it out, without touching
                // a newer token's preview.
                finishingPanel.orderOut(nil)
                self?.closeImmediately(token: finishingToken)
            }
        case .fadeOut:
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Animation.fast
                panel.contentView?.animator().alphaValue = 0
            } completionHandler: { [weak self, finishingPanel = panel] in
                finishingPanel.orderOut(nil)
                self?.closeImmediately(token: finishingToken)
            }
        }
    }

    private func closeImmediately(token: UUID? = nil) {
        guard token.map({ PickyHUDDockExternalDragPreviewGenerationPolicy.mayClose(
            activeToken: model?.presentation.token,
            finishingToken: $0
        ) }) ?? true else { return }
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
