//
//  PickyHUDDockOverflowPolicy.swift
//  Picky
//
//  Pure sizing policy for scrollable dock-rail overflow.
//

import CoreGraphics

struct PickyHUDDockOverflowLayout: Equatable {
    /// Total rail length on its primary axis after applying the screen budget.
    let railLength: CGFloat
    /// Primary-axis space left for the scrollable sessions/groups region once
    /// the persistent handle, add slot, padding, and gaps are reserved.
    let sessionsViewportLength: CGFloat
    let needsScroll: Bool
}

enum PickyHUDDockOverflowPolicy {
    /// Keeps the rail inside the available screen length while reserving its
    /// persistent chrome. The caller owns rendering the sessions viewport as a
    /// ScrollView only when `needsScroll` is true.
    static func layout(
        contentLength: CGFloat,
        availableLength: CGFloat,
        fixedChromeLength: CGFloat
    ) -> PickyHUDDockOverflowLayout {
        let content = max(0, contentLength)
        let available = max(0, availableLength)
        let railLength = min(content, available)
        let fixedChrome = min(max(0, fixedChromeLength), railLength)

        return PickyHUDDockOverflowLayout(
            railLength: railLength,
            sessionsViewportLength: max(0, railLength - fixedChrome),
            needsScroll: content > available
        )
    }
}
