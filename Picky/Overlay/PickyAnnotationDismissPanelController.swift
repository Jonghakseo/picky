//
//  PickyAnnotationDismissPanelController.swift
//  Picky
//
//  Interactive close control for annotations that remain after narration.
//  It lives in a small panel so the full-screen cursor overlay stays click-through.
//

import AppKit
import SwiftUI

enum PickyAnnotationDismissPanelLayout {
    static let panelSize = CGSize(width: 160, height: 44)
    /// Vertical placement measured from the top of the visible frame. 0.8 keeps the
    /// control in the lower third where it stays legible over most desktop content.
    static let verticalPositionFromTop: CGFloat = 0.8

    static func targetScreenIndexes(
        screenFrames: [CGRect],
        annotations: [PickyAgentAnnotation]
    ) -> [Int] {
        screenFrames.indices.filter { index in
            let screenFrame = screenFrames[index]
            return annotations.contains { annotation in
                PickyOverlayGeometry.targetBelongsToScreen(
                    screenLocation: CGPoint(
                        x: annotation.displayFrame.midX,
                        y: annotation.displayFrame.midY
                    ),
                    displayFrame: annotation.displayFrame,
                    screenFrame: screenFrame
                )
            }
        }
    }

    static func panelFrame(visibleFrame: CGRect) -> CGRect {
        // AppKit visible frames are bottom-left origin, so 80% from the top maps to
        // 20% up from the bottom edge.
        let centerX = visibleFrame.midX
        let centerY = visibleFrame.minY + visibleFrame.height * (1 - verticalPositionFromTop)
        return CGRect(
            x: centerX - panelSize.width / 2,
            y: centerY - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

private final class PickyAnnotationDismissPanel: NSPanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PickyAnnotationDismissPanelController {
    private var panels: [PickyAnnotationDismissPanel] = []
    private var presentedVisibleFrames: [CGRect] = []
    private var isSuppressed = false

    func update(
        annotations: [PickyAgentAnnotation],
        isPresented: Bool,
        screens: [NSScreen],
        onDismiss: @escaping @MainActor () -> Void
    ) {
        guard isPresented, !annotations.isEmpty else {
            dismiss()
            return
        }

        let indexes = PickyAnnotationDismissPanelLayout.targetScreenIndexes(
            screenFrames: screens.map(\.frame),
            annotations: annotations
        )
        let targetScreens = indexes.map { screens[$0] }
        let visibleFrames = targetScreens.map(\.visibleFrame)
        guard !targetScreens.isEmpty else {
            dismiss()
            return
        }
        guard visibleFrames != presentedVisibleFrames else {
            applySuppression()
            return
        }

        dismiss()
        presentedVisibleFrames = visibleFrames
        for screen in targetScreens {
            let panel = makePanel(on: screen, onDismiss: onDismiss)
            panels.append(panel)
            if !isSuppressed {
                panel.orderFrontRegardless()
            }
        }
    }

    func setSuppressed(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        isSuppressed = suppressed
        applySuppression()
    }

    func dismiss() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentViewController = nil
        }
        panels.removeAll()
        presentedVisibleFrames = []
    }

    private func applySuppression() {
        for panel in panels {
            if isSuppressed {
                panel.orderOut(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
    }

    private func makePanel(
        on screen: NSScreen,
        onDismiss: @escaping @MainActor () -> Void
    ) -> PickyAnnotationDismissPanel {
        let frame = PickyAnnotationDismissPanelLayout.panelFrame(visibleFrame: screen.visibleFrame)
        let panel = PickyAnnotationDismissPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .pickyCursorOverlay
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.sharingType = .none

        let host = NSHostingController(rootView: LocalizedHostingRoot {
            PickyAnnotationDismissButton(onDismiss: onDismiss)
        })
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: PickyAnnotationDismissPanelLayout.panelSize)
        host.view.autoresizingMask = [.width, .height]
        panel.contentViewController = host
        panel.setFrame(frame, display: true)
        return panel
    }
}

private struct PickyAnnotationDismissButton: View {
    let onDismiss: @MainActor () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "xmark")
                    .font(.system(size: PickyHUDTypography.Size.status, weight: .semibold))
                Text("annotation.dismiss.button")
                    .font(PickyHUDTypography.supportingSemibold)
            }
        }
        .buttonStyle(PickyAnnotationDismissButtonStyle())
        .accessibilityLabel(Text("annotation.dismiss.accessibility"))
        .help(L10n.t("annotation.dismiss.accessibility"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PickyAnnotationDismissButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(
                Capsule()
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            // Component-level transient elevation keeps this tiny control legible over
            // arbitrary desktop content without adding chrome to the annotation itself.
            .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed { return DS.Colors.surface3 }
        if isHovered { return DS.Colors.surface2 }
        return DS.Colors.surface1
    }
}
