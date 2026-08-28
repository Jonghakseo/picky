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
    let session: PickyHUDDockSession
    let sourceFrame: CGRect
    let pointerScreenPoint: CGPoint
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
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
        committed: Bool,
        sourceFrame: CGRect,
        reduceMotion: Bool,
        sourceIsUsable: Bool
    ) -> PickyHUDDockExternalDragPreviewTerminal {
        guard !committed else { return .dismiss }
        // Reduce Motion suppresses every terminal animation, including the
        // otherwise subtle fade used when a source return is unavailable.
        guard !reduceMotion else { return .dismiss }
        guard sourceIsUsable, sourceFrameIsUsable(sourceFrame) else { return .fadeOut }
        return .returnToSource(CGPoint(x: sourceFrame.midX, y: sourceFrame.midY))
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
    func finish(committed: Bool)
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
    private var sourceIsUsable: () -> Bool
    private var reduceMotion: () -> Bool

    init(
        sourceIsUsable: @escaping () -> Bool = { true },
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
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
    }

    func update(pointerScreenPoint: CGPoint, destination: PickyDockContainer?) {
        guard let panel, let model else { return }
        model.destination = destination
        panel.setFrame(
            PickyHUDDockExternalDragPreviewPresentationPolicy.frame(
                pointerScreenPoint: pointerScreenPoint,
                metrics: model.presentation.metrics
            ),
            display: true
        )
    }

    func finish(committed: Bool) {
        guard let panel, let model else { return }
        let terminal = PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            committed: committed,
            sourceFrame: model.presentation.sourceFrame,
            reduceMotion: reduceMotion(),
            sourceIsUsable: sourceIsUsable()
        )
        switch terminal {
        case .dismiss:
            closeImmediately()
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
            } completionHandler: { [weak self] in
                self?.closeImmediately()
            }
        case .fadeOut:
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Animation.fast
                panel.contentView?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.closeImmediately()
            }
        }
    }

    private func closeImmediately() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
