//
//  PickyHUDDockGroupPickerVisibilityPolicy.swift
//  Picky
//
//  Resolves which group badges are safe popover anchors in a scrolling dock.
//

import CoreGraphics
import Foundation

/// A group picker may anchor to a folder badge only while that badge is inside
/// the scroll viewport. SwiftUI keeps offscreen items in the render tree, so
/// projected IDs alone are not evidence that an anchor is visible.
enum PickyHUDPickerAnchorVisibilityPolicy {
    static func visibleAnchorGroupIDs(
        renderedGroupIDs: Set<String>,
        badgeFrames: [String: CGRect],
        viewportFrame: CGRect,
        needsScroll: Bool
    ) -> Set<String> {
        guard needsScroll else { return renderedGroupIDs }
        guard viewportFrame != .zero else { return [] }
        return Set(renderedGroupIDs.filter { groupID in
            guard let badgeFrame = badgeFrames[groupID], !badgeFrame.isNull else { return false }
            return badgeFrame.intersects(viewportFrame)
        })
    }
}
