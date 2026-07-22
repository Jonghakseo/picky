//
//  CompanionResponseOverlay.swift
//  Picky
//
//  Cursor-following overlay that displays streaming AI response text.
//  Uses a non-activating NSPanel so it floats above all apps without
//  stealing focus, and repositions itself near the mouse cursor each frame.
//

import AppKit
import Combine
import SwiftUI

private final class CompanionResponsePanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow {}

/// Single source of truth for the cursor response bubble's typography and line budget.
/// Shared by the SwiftUI view (truncation + lineLimit) and the panel sizing path
/// (`resizePanelToFitContent`) so the host panel never grows past the visible 16-line cap
/// even when `NSHostingView.fittingSize` ignores SwiftUI's lineLimit on multi-paragraph
/// AttributedStrings.
private enum CompanionResponseOverlayMetrics {
    static let maxLines: Int = 16
    static let bubbleFontSize: CGFloat = 13
    static let lineSpacing: CGFloat = 3
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 10
    static let cornerRadius: CGFloat = DS.CornerRadius.extraLarge

    static var bubbleFont: NSFont {
        .systemFont(ofSize: bubbleFontSize, weight: .regular)
    }

    static func maxBubbleHeight() -> CGFloat {
        PickyBubbleLayout.maxBubbleHeight(
            font: bubbleFont,
            lineSpacing: lineSpacing,
            maxLines: maxLines,
            verticalPadding: verticalPadding
        )
    }
}

// MARK: - View Model

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var streamingResponseText: String = ""
    @Published var isShowingResponse: Bool = false
}

// MARK: - Overlay Manager

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var cursorTrackingTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?

    /// The horizontal offset from the cursor to the left edge of the overlay panel.
    private let cursorOffsetX: CGFloat = 22
    /// The vertical offset from the cursor downward to the top edge of the overlay panel.
    private let cursorOffsetY: CGFloat = 6
    /// Maximum width of the overlay panel.
    private let overlayMaxWidth: CGFloat = 340

    func showOverlayAndBeginStreaming() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        overlayViewModel.streamingResponseText = ""
        overlayViewModel.isShowingResponse = true
        createOverlayPanelIfNeeded()
        startCursorTracking()
        overlayPanel?.alphaValue = 1
        overlayPanel?.orderFrontRegardless()
    }

    func updateStreamingText(_ accumulatedText: String) {
        overlayViewModel.streamingResponseText = accumulatedText
        resizePanelToFitContent()
    }

    func finishStreaming() {
        // Keep the response visible for a few seconds after streaming ends,
        // then fade out so the user has time to read the last chunk.
        let hideWork = DispatchWorkItem { [weak self] in
            self?.fadeOutAndHide()
        }
        autoHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: hideWork)
    }

    func hideOverlay() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        stopCursorTracking()
        overlayViewModel.isShowingResponse = false
        overlayViewModel.streamingResponseText = ""
        overlayPanel?.orderOut(nil)
    }

    // MARK: - Private

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: overlayMaxWidth, height: 40)
        let responseOverlayPanel = CompanionResponsePanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        responseOverlayPanel.level = .statusBar
        responseOverlayPanel.isOpaque = false
        responseOverlayPanel.backgroundColor = .clear
        responseOverlayPanel.hasShadow = false
        responseOverlayPanel.ignoresMouseEvents = true
        responseOverlayPanel.hidesOnDeactivate = false
        responseOverlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        responseOverlayPanel.isExcludedFromWindowsMenu = true

        let viewModel = overlayViewModel
        let maxWidth = overlayMaxWidth
        let hostingView = NSHostingView(
            rootView: LocalizedHostingRoot {
                CompanionResponseOverlayView(viewModel: viewModel)
                    .frame(maxWidth: maxWidth)
            }
        )
        hostingView.frame = initialFrame
        responseOverlayPanel.contentView = hostingView

        overlayPanel = responseOverlayPanel
    }

    private func startCursorTracking() {
        // 60fps cursor tracking so the panel stays glued to the mouse
        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanelNearCursor()
            }
        }
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
    }

    private func repositionPanelNearCursor() {
        guard let overlayPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let panelSize = overlayPanel.frame.size

        // Position the panel to the right of and slightly below the cursor.
        // In macOS screen coordinates, Y increases upward, so "below" means
        // subtracting from the cursor Y.
        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelSize.height

        // Clamp to the visible frame of the screen containing the cursor
        // so the panel never goes off-screen.
        if let currentScreen = screenContainingPoint(mouseLocation) {
            let visibleFrame = currentScreen.visibleFrame

            // If the panel would go off the right edge, flip it to the left of the cursor
            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelSize.width
            }

            // If the panel would go below the bottom edge, push it above the cursor
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }

            // Final clamp
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        overlayPanel.setFrameOrigin(CGPoint(x: panelOriginX, y: panelOriginY))
    }

    private func resizePanelToFitContent() {
        guard let overlayPanel, let contentView = overlayPanel.contentView else { return }

        let fittingSize = contentView.fittingSize
        let newWidth = min(fittingSize.width, overlayMaxWidth)
        // Cap the host panel at the visible-line budget. `NSHostingView.fittingSize` can return
        // the ideal vertical size for the entire AttributedString (ignoring SwiftUI's lineLimit)
        // when `fixedSize(vertical: true)` is in play, which previously let multi-paragraph
        // replies grow the bubble well past 16 lines. The truncation inside the SwiftUI view
        // keeps the visible text bounded; this min() keeps the host panel from expanding past
        // that same budget even if the SwiftUI cap is ever bypassed.
        let maxHeight = CompanionResponseOverlayMetrics.maxBubbleHeight()
        let newHeight = min(fittingSize.height, maxHeight)

        // Keep the panel origin relative to the cursor (the timer handles that),
        // but update the frame size so the content fits.
        var frame = overlayPanel.frame
        let heightDelta = newHeight - frame.height
        frame.size = CGSize(width: newWidth, height: newHeight)
        // Adjust origin Y so the panel grows upward (toward the cursor), not downward
        frame.origin.y -= heightDelta
        overlayPanel.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func fadeOutAndHide() {
        guard let overlayPanel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            overlayPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.hideOverlay()
            }
        })
    }

    private func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

// MARK: - SwiftUI View

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel

    var body: some View {
        if viewModel.isShowingResponse {
            let responseText = viewModel.streamingResponseText.isEmpty ? "..." : viewModel.streamingResponseText
            let renderedText = PickyBubbleMarkdown.displayString(for: responseText)
            let rawAttributed = PickyBubbleMarkdown.attributedText(for: responseText)
            let textWidth = PickyBubbleLayout.textWidth(
                for: renderedText,
                font: CompanionResponseOverlayMetrics.bubbleFont,
                maxWidth: 300
            )
            // Pre-truncate to the visible-line budget so the resulting `fittingSize` and the
            // rendered text agree on "16 lines max". SwiftUI's `.lineLimit` is kept as a
            // belt-and-braces safety net for the rare case CoreText line counting disagrees
            // with SwiftUI's wrapping (different font fallback, locale-specific shaping).
            let attributedText = PickyBubbleLayout.truncatedAttributedText(
                rawAttributed,
                font: CompanionResponseOverlayMetrics.bubbleFont,
                lineSpacing: CompanionResponseOverlayMetrics.lineSpacing,
                width: textWidth,
                maxLines: CompanionResponseOverlayMetrics.maxLines
            )
            Text(attributedText)
                .font(.system(size: CompanionResponseOverlayMetrics.bubbleFontSize, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(CompanionResponseOverlayMetrics.lineSpacing)
                .multilineTextAlignment(.leading)
                .lineLimit(CompanionResponseOverlayMetrics.maxLines)
                .truncationMode(.tail)
                .frame(width: textWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CompanionResponseOverlayMetrics.horizontalPadding)
                .padding(.vertical, CompanionResponseOverlayMetrics.verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: CompanionResponseOverlayMetrics.cornerRadius, style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: CompanionResponseOverlayMetrics.cornerRadius, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
                )
                .clipped()
        }
    }
}
