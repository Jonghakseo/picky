//
//  PickyHUDDockListChrome.swift
//  Picky
//
//  Resize tab and scroll fades of the list dock.
//

import SwiftUI

// MARK: - Resize

/// Maps a resize-tab drag onto an S/M/L preset. The dock's free edge faces
/// the screen interior, so dragging toward the interior widens a vertical
/// dock and thickens a horizontal one.
///
/// Presets are a step scale, not a continuous width: a fixed pointer distance
/// buys one step in either direction. Snapping to the nearest preset *width*
/// instead would make a horizontal dock, whose three thicknesses are only a
/// few points apart, change size after a 2pt twitch.
enum PickyHUDDockResizePolicy {
    /// Pointer distance along the growth axis that one preset step costs.
    static let stepDistance: CGFloat = 40

    /// Growth along the cross axis for a screen-space drag (AppKit, Y up).
    static func growth(screenDelta: CGPoint, dockSide: PickyHUDDockSide) -> CGFloat {
        switch dockSide {
        case .right: -screenDelta.x
        case .left: screenDelta.x
        case .bottom: screenDelta.y
        case .top: -screenDelta.y
        }
    }

    /// Resolves the preset for a drag that began at `start` while `current` is
    /// applied. Stepping back out of the applied preset needs half a step more
    /// travel than entering it did, so a pointer resting on a boundary cannot
    /// flip the dock between two sizes.
    static func preset(
        start: PickyHUDDockSizePreset,
        current: PickyHUDDockSizePreset,
        screenDelta: CGPoint,
        dockSide: PickyHUDDockSide
    ) -> PickyHUDDockSizePreset {
        let presets = PickyHUDDockSizePreset.allCases
        guard let startIndex = presets.firstIndex(of: start) else { return current }
        let distance = growth(screenDelta: screenDelta, dockSide: dockSide)
        guard distance.isFinite else { return current }
        let steps = Int((distance / stepDistance).rounded(.towardZero))
        let index = min(max(startIndex + steps, presets.startIndex), presets.count - 1)
        guard let currentIndex = presets.firstIndex(of: current) else { return presets[index] }
        let appliedDistance = CGFloat(currentIndex - startIndex) * stepDistance
        if abs(index - currentIndex) == 1,
           abs(index - startIndex) < abs(currentIndex - startIndex),
           abs(distance - appliedDistance) < stepDistance / 2 {
            return current
        }
        return presets[index]
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
