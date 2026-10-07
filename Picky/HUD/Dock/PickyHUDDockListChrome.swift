//
//  PickyHUDDockListChrome.swift
//  Picky
//
//  Resize tab and scroll fades of the list dock.
//

import SwiftUI

// MARK: - Resize

/// Maps a resize-tab drag onto the nearest S/M/L preset. The dock's free
/// edge faces the screen interior, so dragging toward the interior widens a
/// vertical dock and thickens a horizontal one.
enum PickyHUDDockResizePolicy {
    /// Cross size a preset gives the rail: list width for a vertical dock,
    /// thickness for a horizontal one.
    static func crossSize(
        of preset: PickyHUDDockSizePreset,
        orientation: PickyHUDDockOrientation,
        fontScale: CGFloat
    ) -> CGFloat {
        let metrics = PickyHUDDockMetrics(preset: preset)
        return orientation == .vertical
            ? metrics.listWidth
            : metrics.horizontalThickness(fontScale: fontScale)
    }

    /// Growth along the cross axis for a screen-space drag (AppKit, Y up).
    static func growth(screenDelta: CGPoint, dockSide: PickyHUDDockSide) -> CGFloat {
        switch dockSide {
        case .right: -screenDelta.x
        case .left: screenDelta.x
        case .bottom: screenDelta.y
        case .top: -screenDelta.y
        }
    }

    static func preset(
        start: PickyHUDDockSizePreset,
        screenDelta: CGPoint,
        dockSide: PickyHUDDockSide,
        fontScale: CGFloat
    ) -> PickyHUDDockSizePreset {
        let orientation = dockSide.orientation
        let desired = crossSize(of: start, orientation: orientation, fontScale: fontScale)
            + growth(screenDelta: screenDelta, dockSide: dockSide)
        return PickyHUDDockSizePreset.allCases.min { lhs, rhs in
            abs(crossSize(of: lhs, orientation: orientation, fontScale: fontScale) - desired)
                < abs(crossSize(of: rhs, orientation: orientation, fontScale: fontScale) - desired)
        } ?? start
    }
}

/// A tab that sticks out of the dock's free edge. Unlike the move handle's
/// inward notch, its outward shape marks it as the resize affordance.
struct PickyHUDDockResizeTab: View {
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    let isActive: Bool

    var body: some View {
        let horizontal = dockSide.orientation == .horizontal
        let shape = tabShape
        ZStack {
            shape.fill(isActive ? DS.Colors.surface4 : DS.Colors.surface3)
            shape.stroke(DS.Colors.borderStrong, lineWidth: 0.5)
            Capsule()
                .fill(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(width: horizontal ? 14 : 2, height: horizontal ? 2 : 14)
        }
        .frame(
            width: horizontal ? metrics.resizeTabLength : metrics.resizeTabDepth,
            height: horizontal ? metrics.resizeTabDepth : metrics.resizeTabLength
        )
        .shadow(color: .black.opacity(0.12), radius: 2) // design-token-exception: small lift that separates the tab from the card behind it.
    }

    /// Rounded on the outward side, square where it meets the dock.
    private var tabShape: UnevenRoundedRectangle {
        let radius: CGFloat = 5
        switch dockSide {
        case .right:
            return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, style: .continuous)
        case .left:
            return UnevenRoundedRectangle(bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
        case .bottom:
            return UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
        case .top:
            return UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
        }
    }
}

// MARK: - Scroll fades

struct PickyHUDDockScrollFades: Equatable {
    var leading: Bool
    var trailing: Bool
}

/// Fades only the edge that hides content.
enum PickyHUDDockScrollFadePolicy {
    static func fades(offset: CGFloat, contentLength: CGFloat, viewportLength: CGFloat) -> PickyHUDDockScrollFades {
        guard contentLength > viewportLength + 0.5 else { return .init(leading: false, trailing: false) }
        return .init(
            leading: offset > 0.5,
            trailing: offset < contentLength - viewportLength - 0.5
        )
    }
}

struct PickyHUDDockScrollFadeMask: View {
    let orientation: PickyHUDDockOrientation
    let fades: PickyHUDDockScrollFades
    let length: CGFloat

    var body: some View {
        let layout = orientation == .horizontal
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        layout {
            gradient(from: fades.leading ? 0 : 1, to: 1)
            Color.black
            gradient(from: 1, to: fades.trailing ? 0 : 1)
        }
    }

    private func gradient(from start: Double, to end: Double) -> some View {
        LinearGradient(
            colors: [.black.opacity(start), .black.opacity(end)],
            startPoint: orientation == .horizontal ? .leading : .top,
            endPoint: orientation == .horizontal ? .trailing : .bottom
        )
        .frame(
            width: orientation == .horizontal ? length : nil,
            height: orientation == .horizontal ? nil : length
        )
    }
}
