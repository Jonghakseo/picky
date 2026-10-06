//
//  PickyInitialBottomScrollAnchor.swift
//  Picky
//
//  Chat-style transcripts must open on their newest content. Scrolling there
//  from `onAppear` / `.task` with `ScrollViewProxy.scrollTo` runs after the
//  freshly mounted ScrollView has already committed a frame at offset 0, so
//  the oldest message flashes for a few frames before the jump.
//
//  Only the initial-offset role is anchored. The single-argument
//  `defaultScrollAnchor(.bottom)` would also bottom-align short transcripts and
//  change how content-size changes move the offset; callers keep owning those
//  through their own pin logic.
//

import SwiftUI

extension View {
    /// Starts a vertical ScrollView at its bottom edge on the first layout.
    /// macOS 14 has no per-role anchor, so it keeps the caller's deferred
    /// scroll as the only bottom pin.
    func pickyInitialBottomScrollAnchor() -> some View {
        modifier(PickyInitialBottomScrollAnchor())
    }
}

private struct PickyInitialBottomScrollAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content
        }
    }
}
