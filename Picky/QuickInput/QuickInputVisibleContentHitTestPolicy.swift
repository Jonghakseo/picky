//
//  QuickInputVisibleContentHitTestPolicy.swift
//  Picky
//
//  Converts SwiftUI-reported Quick Input content bounds into the AppKit
//  coordinate space used by global ink-capture routing.
//

import CoreGraphics

/// Keeps ink pass-through limited to Quick Input pixels that SwiftUI actually
/// renders. The hosting panel also contains transparent shadow margins and,
/// when history is present, transparent transcript space that must remain
/// owned by ink capture rather than leaking to the app underneath.
enum QuickInputVisibleContentHitTestPolicy {
    static func appKitVisibleBounds(
        swiftUIFrames: [CGRect],
        hostingViewSize: CGSize
    ) -> [CGRect] {
        guard isUsable(size: hostingViewSize) else { return [] }

        return swiftUIFrames.compactMap { frame in
            guard isUsable(frame: frame) else { return nil }
            return CGRect(
                x: frame.minX,
                y: hostingViewSize.height - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
    }

    /// In lightweight mode the history card's top band is fully transparent
    /// because its dissolve mask starts at alpha zero. Exclude it before the
    /// frame is translated for AppKit hit testing.
    static func visibleHistoryFrame(
        _ cardFrame: CGRect,
        backgroundMode: QuickInputHistoryBackgroundMode
    ) -> CGRect {
        guard isUsable(frame: cardFrame) else { return .null }
        guard backgroundMode == .lightweight else { return cardFrame }

        let hiddenHeight = cardFrame.height * QuickInputPanelLayout.historyDissolveHiddenLocation
        guard hiddenHeight.isFinite, hiddenHeight >= 0, hiddenHeight < cardFrame.height else {
            return .null
        }
        return CGRect(
            x: cardFrame.minX,
            y: cardFrame.minY + hiddenHeight,
            width: cardFrame.width,
            height: cardFrame.height - hiddenHeight
        )
    }

    static func contains(
        _ point: CGPoint,
        swiftUIFrames: [CGRect],
        hostingViewSize: CGSize
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        return appKitVisibleBounds(
            swiftUIFrames: swiftUIFrames,
            hostingViewSize: hostingViewSize
        ).contains(where: { $0.contains(point) })
    }

    private static func isUsable(frame: CGRect) -> Bool {
        !frame.isNull
            && !frame.isInfinite
            && frame.width > 0
            && frame.height > 0
            && frame.minX.isFinite
            && frame.minY.isFinite
            && frame.maxX.isFinite
            && frame.maxY.isFinite
    }

    private static func isUsable(size: CGSize) -> Bool {
        size.width > 0
            && size.height > 0
            && size.width.isFinite
            && size.height.isFinite
    }
}
