import SwiftUI

/// A single shell grows toward the screen interior. Its icon row and the
/// surrounding reserved footprint never move when the name row is revealed.
struct PickyHUDHorizontalDockChrome<Content: View, Utilities: View, Handle: View, Preview: View>: View, @preconcurrency Animatable {
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    let railLength: CGFloat
    let cellSide: CGFloat
    let previewHeight: CGFloat
    var revealedHeight: CGFloat
    let onMinimize: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var utilities: () -> Utilities
    @ViewBuilder var handle: () -> Handle
    @ViewBuilder var preview: () -> Preview
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var animatableData: CGFloat {
        get { revealedHeight }
        set { revealedHeight = newValue }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.outerCornerRadius, style: .continuous)
        VStack(spacing: 0) {
            if dockSide == .bottom { nameRow }
            HStack(spacing: 0) {
                handle().frame(width: metrics.horizontalCompactHandleWidth, height: cellSide)
                content()
                Rectangle().fill(DS.Colors.borderSubtle)
                    .frame(width: metrics.chromeSeparatorThickness, height: metrics.utilityButtonSide - 6)
                    .frame(width: metrics.horizontalCompactSeparatorWidth, height: cellSide)
                utilities()
                Color.clear.frame(width: metrics.collapseHitDepth, height: cellSide)
            }
            .frame(width: railLength, height: cellSide)
            if dockSide == .top { nameRow }
        }
        .frame(width: railLength, height: cellSide + max(0, revealedHeight))
        .background {
            Group {
                if reduceTransparency { DS.Colors.surface1 }
                else { PickyHUDDockNativeMaterial().overlay(DS.Colors.dockShellScrim) }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3) // design-token-exception: shared dock shell elevation.
        }
        .overlay {
            PickyHUDDockCollapseNotch(dockSide: dockSide, metrics: metrics, edgeLength: cellSide, onMinimize: onMinimize)
                .frame(height: cellSide)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: dockSide == .top ? .topTrailing : .bottomTrailing)
                .clipShape(shape)
        }
        .background(PickyHUDVisibleChromeFrameReporter())
    }

    private var nameRow: some View {
        preview()
            .padding(.horizontal, DS.Spacing.space3)
            .frame(width: railLength, height: previewHeight)
            .frame(height: max(0, revealedHeight), alignment: dockSide == .top ? .top : .bottom)
            .clipped()
            .opacity(Double(min(1, max(0, revealedHeight / max(1, previewHeight)))))
            .allowsHitTesting(revealedHeight >= previewHeight - 0.5)
            .accessibilityHidden(revealedHeight < previewHeight - 0.5)
    }
}
