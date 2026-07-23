//
//  PickyCaptureContextPanelController.swift
//  Picky
//
//  Interactive per-display screen-context control. It uses compact panels so
//  the full-screen cursor overlay can remain click-through.
//

import AppKit
import Combine
import SwiftUI

enum PickyCaptureContextControlPanelLayout {
    static let panelSize = CGSize(width: 420, height: 48)
    static let topInset: CGFloat = 56

    static func panelFrame(screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - topInset - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

private final class PickyCaptureContextControlPanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PickyCaptureContextPanelController {
    private var panels: [PickyCaptureContextControlPanel] = []
    private var captureStateObservation: AnyCancellable?
    private weak var companionManager: CompanionManager?
    private var isCaptureActive = false

    func bind(to companionManager: CompanionManager) {
        unbind()
        self.companionManager = companionManager
        captureStateObservation = companionManager.$voiceState
            .combineLatest(companionManager.$isQuickInputPanelVisible)
            .map { voiceState, isQuickInputVisible in
                voiceState == .listening || isQuickInputVisible
            }
            .removeDuplicates()
            .sink { [weak self] isActive in
                guard let self else { return }
                self.isCaptureActive = isActive
                if isActive {
                    self.rebuildPanels(screens: NSScreen.screens)
                } else {
                    self.dismissPanels()
                }
            }
    }

    func refreshScreens(_ screens: [NSScreen]) {
        guard isCaptureActive else { return }
        rebuildPanels(screens: screens)
    }

    func unbind() {
        captureStateObservation?.cancel()
        captureStateObservation = nil
        companionManager = nil
        isCaptureActive = false
        dismissPanels()
    }

    private func rebuildPanels(screens: [NSScreen]) {
        guard let companionManager else {
            dismissPanels()
            return
        }

        dismissPanels()
        for screen in screens {
            guard let displayID = screen.pickyDisplayID else { continue }
            let panel = makePanel(
                screenFrame: screen.frame,
                displayID: displayID,
                companionManager: companionManager
            )
            panels.append(panel)
            panel.orderFrontRegardless()
        }
    }

    private func dismissPanels() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentViewController = nil
        }
        panels.removeAll()
    }

    private func makePanel(
        screenFrame: CGRect,
        displayID: CGDirectDisplayID,
        companionManager: CompanionManager
    ) -> PickyCaptureContextControlPanel {
        let frame = PickyCaptureContextControlPanelLayout.panelFrame(screenFrame: screenFrame)
        let panel = PickyCaptureContextControlPanel(
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
            PickyCaptureContextControlView(
                screenFrame: screenFrame,
                displayID: displayID,
                companionManager: companionManager
            )
        })
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: PickyCaptureContextControlPanelLayout.panelSize)
        host.view.autoresizingMask = [.width, .height]
        panel.contentViewController = host
        panel.setFrame(frame, display: true)
        return panel
    }
}

private struct PickyCaptureContextControlView: View {
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
    @ObservedObject var companionManager: CompanionManager

    private var hasInk: Bool {
        let region = screenFrame.insetBy(dx: -1, dy: -1)
        return companionManager.inkOverlayState.strokes.contains { stroke in
            stroke.points.contains { region.contains($0) }
        }
    }

    private var isIncluded: Bool {
        companionManager.isScreenIncludedAsContext(
            displayID: displayID,
            isFocused: companionManager.screenContextFocusedDisplayID == displayID,
            hasInk: hasInk
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isIncluded ? DS.Colors.overlayCursorBlue : Color.white.opacity(0.38))
                .frame(width: 7, height: 7)

            Text(L10n.t(isIncluded
                ? "overlay.captureBorder.contextLabel"
                : "overlay.captureBorder.notIncludedLabel"))
                .font(PickyHUDTypography.statusMedium)
                .foregroundStyle(Color.white.opacity(isIncluded ? 0.92 : 0.78))
                .lineLimit(1)

            Divider()
                .overlay(Color.white.opacity(0.22))
                .frame(height: 14)

            Button {
                companionManager.toggleScreenContextDisplay(
                    displayID: displayID,
                    isFocused: companionManager.screenContextFocusedDisplayID == displayID,
                    hasInk: hasInk
                )
            } label: {
                Text(L10n.t(isIncluded
                    ? "overlay.captureBorder.cancel"
                    : "overlay.captureBorder.include"))
                    .font(PickyHUDTypography.statusSemibold)
            }
            .buttonStyle(PickyCaptureContextInlineButtonStyle(isIncluded: isIncluded))
            .accessibilityLabel(Text(L10n.t(isIncluded
                ? "overlay.captureBorder.cancel"
                : "overlay.captureBorder.include")))
            .accessibilityValue(Text(L10n.t(isIncluded
                ? "overlay.captureBorder.contextLabel"
                : "overlay.captureBorder.notIncludedLabel")))
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.76))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    isIncluded
                        ? DS.Colors.overlayCursorBlue.opacity(0.35)
                        : Color.white.opacity(0.18),
                    lineWidth: 0.8
                )
        )
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PickyCaptureContextInlineButtonStyle: ButtonStyle {
    let isIncluded: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isIncluded ? Color.white.opacity(0.9) : DS.Colors.overlayCursorBlue)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .contentShape(Capsule(style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed { return Color.white.opacity(0.22) }
        if isHovered { return Color.white.opacity(0.14) }
        return Color.white.opacity(0.08)
    }
}
