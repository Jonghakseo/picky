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

/// Converts the SwiftUI-rendered capsule frame into the AppKit coordinate
/// space used by both the panel's event dispatch and global overlay routing.
enum PickyCaptureContextControlHitTestPolicy {
    static func appKitVisibleBounds(
        visibleContentFrame: CGRect,
        hostingViewSize: CGSize
    ) -> CGRect {
        guard !visibleContentFrame.isNull,
              visibleContentFrame.width > 0,
              visibleContentFrame.height > 0,
              hostingViewSize.width > 0,
              hostingViewSize.height > 0 else {
            return .null
        }
        return CGRect(
            x: visibleContentFrame.minX,
            y: hostingViewSize.height - visibleContentFrame.maxY,
            width: visibleContentFrame.width,
            height: visibleContentFrame.height
        )
    }

    static func contains(
        _ point: CGPoint,
        visibleContentFrame: CGRect,
        hostingViewSize: CGSize
    ) -> Bool {
        appKitVisibleBounds(
            visibleContentFrame: visibleContentFrame,
            hostingViewSize: hostingViewSize
        ).contains(point)
    }
}

@MainActor
private final class PickyCaptureContextControlViewModel: ObservableObject {
    /// SwiftUI reports the rendered capsule geometry in the hosting view's
    /// coordinate space, leaving transparent panel margins click-through.
    @Published var visibleContentFrame = CGRect.null
}

private final class PickyCaptureContextControlHostingView: NSHostingView<LocalizedHostingRoot<PickyCaptureContextControlView>> {
    private let visibleContentFrame: () -> CGRect

    required init(rootView: LocalizedHostingRoot<PickyCaptureContextControlView>) {
        visibleContentFrame = { .null }
        super.init(rootView: rootView)
    }

    init(
        rootView: LocalizedHostingRoot<PickyCaptureContextControlView>,
        visibleContentFrame: @escaping () -> CGRect
    ) {
        self.visibleContentFrame = visibleContentFrame
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        nil
    }

    func containsInteractivePoint(_ point: NSPoint) -> Bool {
        PickyCaptureContextControlHitTestPolicy.contains(
            point,
            visibleContentFrame: visibleContentFrame(),
            hostingViewSize: bounds.size
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsInteractivePoint(point) else { return nil }
        return super.hitTest(point)
    }
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
        companionManager.setScreenContextControlHitTest { [weak self] point in
            self?.containsInteractiveGlobalPoint(point) == true
        }
        captureStateObservation = companionManager.$voiceState
            .combineLatest(companionManager.$isQuickInputScreenContextControlsVisible)
            .map { voiceState, isQuickInputControlsVisible in
                voiceState == .listening || isQuickInputControlsVisible
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

    func containsInteractiveGlobalPoint(_ point: CGPoint) -> Bool {
        panels.contains { panel in
            guard panel.isVisible,
                  let hostingView = panel.contentView as? PickyCaptureContextControlHostingView else {
                return false
            }
            let windowPoint = panel.convertPoint(fromScreen: point)
            let hostingViewPoint = hostingView.convert(windowPoint, from: nil)
            return hostingView.containsInteractivePoint(hostingViewPoint)
        }
    }

    func unbind() {
        captureStateObservation?.cancel()
        captureStateObservation = nil
        companionManager?.setScreenContextControlHitTest(nil)
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
            panel.contentView = nil
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

        let viewModel = PickyCaptureContextControlViewModel()
        let host = PickyCaptureContextControlHostingView(
            rootView: LocalizedHostingRoot {
                PickyCaptureContextControlView(
                    screenFrame: screenFrame,
                    displayID: displayID,
                    companionManager: companionManager,
                    viewModel: viewModel
                )
            },
            visibleContentFrame: { [weak viewModel] in
                viewModel?.visibleContentFrame ?? .null
            }
        )
        host.frame = NSRect(origin: .zero, size: PickyCaptureContextControlPanelLayout.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(frame, display: true)
        return panel
    }
}

private struct PickyCaptureContextControlVisibleContentFramePreferenceKey: PreferenceKey {
    static var defaultValue = CGRect.null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = value.union(nextValue())
    }
}

private struct PickyCaptureContextControlView: View {
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var viewModel: PickyCaptureContextControlViewModel

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
        .background(visibleContentFrameReporter)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "PickyCaptureContextControl")
        .onPreferenceChange(PickyCaptureContextControlVisibleContentFramePreferenceKey.self) {
            viewModel.visibleContentFrame = $0
        }
    }

    private var visibleContentFrameReporter: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PickyCaptureContextControlVisibleContentFramePreferenceKey.self,
                value: proxy.frame(in: .named("PickyCaptureContextControl"))
            )
        }
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
