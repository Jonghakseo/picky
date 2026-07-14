//
//  OnboardingHighlightViewerPanelController.swift
//  Picky
//
//  Small floating panel that previews "what Picky just captured" right after
//  the user finishes circling a region. Shows the screen capture as the
//  background and the ink strokes the user drew on top, with a caption
//  explaining that this composite is what gets shipped along with their
//  prompt as context.
//
//  The panel is informational only \u2014 it auto-dismisses after a short dwell so
//  the demo keeps moving, and the user can click it to close early. Lives in
//  its own NSPanel so it can sit alongside the Picky cursor bubble and the
//  HUD dock without competing for screen real estate.
//

import AppKit
import SwiftUI

private final class OnboardingHighlightViewerPanel: NSPanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class OnboardingHighlightViewerPanelController {
    private var panel: OnboardingHighlightViewerPanel?
    private var dismissTask: Task<Void, Never>?

    func present(
        screenshotJPEG: Data,
        strokes: [PickyInkOverlayStroke],
        capturedDisplayFrame: CGRect,
        dwellSeconds: Double
    ) {
        dismiss()

        let screen = NSScreen.main ?? NSScreen.screens.first
        let panelSize = NSSize(width: 360, height: 270)
        let frame = computeFrame(of: screen, size: panelSize)

        let panel = OnboardingHighlightViewerPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let view = OnboardingHighlightViewerView(
            screenshotJPEG: screenshotJPEG,
            strokes: strokes,
            capturedDisplayFrame: capturedDisplayFrame,
            onClose: { [weak self] in self?.dismiss() }
        )
        let host = NSHostingController(rootView: LocalizedHostingRoot { view })
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: panelSize)
        host.view.autoresizingMask = [.width, .height]
        panel.contentViewController = host
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dwellSeconds * 1_000_000_000))
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func computeFrame(of screen: NSScreen?, size: NSSize) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Sit at top-center so the cursor bubble (which floats near the
        // cursor) and the HUD dock (right or left edge) don't fight us for
        // pixels.
        let originX = visible.midX - size.width / 2
        let originY = visible.maxY - size.height - 32
        return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
    }
}

private struct OnboardingHighlightViewerView: View {
    let screenshotJPEG: Data
    let strokes: [PickyInkOverlayStroke]
    let capturedDisplayFrame: CGRect
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                    .foregroundColor(.white.opacity(0.7))
                Text("onboarding.highlight.header")
                    .pickyFont(size: 12, weight: .semibold)
                    .foregroundColor(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .pickyFont(size: 10, weight: .semibold)
                        .foregroundColor(.white.opacity(0.6))
                        .padding(4)
                }
                .buttonStyle(.plain)
            }

            ZStack(alignment: .topLeading) {
                if let image = NSImage(data: screenshotJPEG) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                GeometryReader { geo in
                    Canvas { context, _ in
                        let scaleX = geo.size.width / max(capturedDisplayFrame.width, 1)
                        let scaleY = geo.size.height / max(capturedDisplayFrame.height, 1)
                        for stroke in strokes {
                            var path = Path()
                            for (index, point) in stroke.points.enumerated() {
                                // Convert global AppKit point to display-local
                                // by subtracting the display origin, then flip Y
                                // because the JPEG is top-down while AppKit is
                                // bottom-up.
                                let localX = (point.x - capturedDisplayFrame.minX) * scaleX
                                let localYFromBottom = (point.y - capturedDisplayFrame.minY) * scaleY
                                let localY = geo.size.height - localYFromBottom
                                let canvasPoint = CGPoint(x: localX, y: localY)
                                if index == 0 {
                                    path.move(to: canvasPoint)
                                } else {
                                    path.addLine(to: canvasPoint)
                                }
                            }
                            context.stroke(
                                path,
                                with: .color(Color(red: 1.0, green: 0.85, blue: 0.2).opacity(stroke.opacity)),
                                style: StrokeStyle(
                                    lineWidth: max(stroke.strokeWidth * scaleX, 1.5),
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 18, x: 0, y: 8)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
