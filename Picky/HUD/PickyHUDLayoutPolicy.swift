//
//  PickyHUDLayoutPolicy.swift
//  Picky
//
//  Pure HUD expansion and content visibility policy.
//

import SwiftUI

enum PickyHUDExpansion {
    static let duration: TimeInterval = 0.22
    static let panelShrinkDelay: TimeInterval = duration + 0.03
    static let animation = Animation.easeInOut(duration: duration)
    static let outerPadding: CGFloat = 11
    static let dockShadowOpacity = 0.14
    static let dockShadowRadius: CGFloat = 8
    static let dockShadowYOffset: CGFloat = 6
    // SwiftUI shadows are drawn outside layout bounds. Give the transparent NSPanel
    // explicit chrome bleed so the dock's blur tail is not clipped at the hosting
    // view edge. Vertical bleed is asymmetric because the main shadow is offset down.
    static let dockShadowHorizontalExtraBleed: CGFloat = 3
    static let dockShadowVerticalExtraBleed: CGFloat = 5
    static var dockShadowHorizontalPadding: CGFloat {
        dockShadowRadius + dockShadowHorizontalExtraBleed
    }
    static var dockShadowTopPadding: CGFloat {
        dockShadowRadius + max(0, -dockShadowYOffset) + dockShadowVerticalExtraBleed
    }
    static var dockShadowBottomPadding: CGFloat {
        dockShadowRadius + max(0, dockShadowYOffset) + dockShadowVerticalExtraBleed
    }
    static var dockShadowInsets: EdgeInsets {
        EdgeInsets(
            top: dockShadowTopPadding,
            leading: dockShadowHorizontalPadding,
            bottom: dockShadowBottomPadding,
            trailing: dockShadowHorizontalPadding
        )
    }
    static var dockShadowVerticalPadding: CGFloat {
        dockShadowTopPadding + dockShadowBottomPadding
    }
    static let dockTightShadowOpacity = 0.06
    static let dockTightShadowRadius: CGFloat = 1.5
    static let dockTightShadowYOffset: CGFloat = 0.5
    static let cardShadowOpacity = 0.12
    static let cardShadowRadius: CGFloat = 8
    static let cardShadowYOffset: CGFloat = 4
    /// Hit area height for the drag handle that lives INSIDE the dock capsule's top
    /// row. Comfortably larger than the visible pill so the handle is easy to grab;
    /// the pill is overlaid centered inside this frame. Because the handle is now a
    /// child of the dock capsule, this height does NOT contribute to
    /// `dockBodyTopOffsetFromContentTop` — it consumes space inside the capsule, not
    /// above it. Kept tight (14pt) so the dock doesn't gain a clunky empty band on
    /// top; the surrounding capsule padding still gives a comfortable click target.
    static let dockHandleAreaHeight: CGFloat = 14
    /// Distance from the panel content's top edge (in SwiftUI top-down coords) down
    /// to the dock CAPSULE's top edge. The handle now lives inside the capsule, so
    /// the offset is just the top shadow bleed wrapping the HStack — the anchor
    /// percent maps directly to the visible top of the dock capsule.
    static var dockBodyTopOffsetFromContentTop: CGFloat {
        dockShadowTopPadding
    }
    /// Slack pixels left below the conversation card so it never sits right at the
    /// dock-anchored panel cap. Sub-pixel layout drift (composer auto-grow, status
    /// pill text length, streaming thinking preview) can otherwise momentarily push
    /// the card across the cap and trigger a re-clip the user sees as a twitch.
    static let cardBreathingRoom: CGFloat = 24

    static func cardSpacing(isExpanded: Bool) -> CGFloat {
        isExpanded ? 9 : 0
    }

    static func cardVerticalPadding(isExpanded: Bool) -> CGFloat {
        8
    }

    static func contentFrameHeight(isExpanded: Bool, measuredHeight: CGFloat) -> CGFloat? {
        guard isExpanded else { return 0 }
        return measuredHeight > 0 ? measuredHeight : nil
    }

    static let anchorsContentToPanelTopDuringDeferredShrink = true

    static func shouldDeferPanelShrink(currentHeight: CGFloat, targetHeight: CGFloat, deferShrink: Bool) -> Bool {
        deferShrink && targetHeight < currentHeight - 1
    }

    static func reportedHUDSize(
        measuredSize: CGSize,
        previousReportedSize: CGSize,
        activeSessionChanged: Bool,
        shouldHoldHeight: Bool
    ) -> CGSize {
        guard !activeSessionChanged else { return measuredSize }
        guard shouldHoldHeight,
              previousReportedSize.height > 0,
              measuredSize.height < previousReportedSize.height
        else { return measuredSize }
        return CGSize(width: measuredSize.width, height: previousReportedSize.height)
    }
}

enum PickyHUDDockHold: Equatable {
    case open(String)

    var sessionID: String {
        switch self {
        case let .open(sessionID):
            return sessionID
        }
    }

    func isOpen(sessionID: String) -> Bool {
        self == .open(sessionID)
    }
}

struct PickyHUDDockMetrics: Equatable {
    let preset: PickyHUDDockSizePreset
    let scale: CGFloat

    init(preset: PickyHUDDockSizePreset) {
        self.preset = preset
        self.scale = CGFloat(preset.scale)
    }

    static let medium = PickyHUDDockMetrics(preset: .medium)

    var railWidth: CGFloat { max(sessionTileWidth + (horizontalPadding * 2), scaled(PickyHUDDockLayout.railWidth)) }
    var iconSide: CGFloat { scaled(PickyHUDDockLayout.addSlotButtonSide) }
    var iconCornerRadius: CGFloat { scaled(12) }
    /// Outer dock capsule corner radius. Reduced from a full capsule to a refined
    /// rounded rectangle so the dock reads as a polished panel rather than a pill.
    /// Scales with the preset: S ≈ 10pt, M ≈ 12pt, L = 14pt.
    var outerCornerRadius: CGFloat { scaled(14) }
    var sessionTileWidth: CGFloat { max(40, scaled(54)) }
    var sessionTileHeight: CGFloat { max(42, scaled(54)) }
    var sessionTileCornerRadius: CGFloat { scaled(9) }
    var sessionLogoSide: CGFloat { max(17, scaled(24)) }
    var sessionLabelFontSize: CGFloat { max(10.5, scaled(15)) }
    var sessionSpacing: CGFloat { max(7, scaled(9)) }
    var horizontalPadding: CGFloat { max(3, scaled(4)) }
    var topPadding: CGFloat { max(3, scaled(4)) }
    var bottomPadding: CGFloat { max(8, scaled(10)) }
    var addSlotTopPadding: CGFloat { max(5, scaled(7)) }
    var addSlotButtonSide: CGFloat { iconSide }
    var collapsedAddSlotVisualHeight: CGFloat { max(10, scaled(PickyHUDDockLayout.collapsedAddSlotVisualHeight)) }
    var addSlotCollapsedExpansionReserve: CGFloat { max(0, addSlotButtonSide - collapsedAddSlotVisualHeight) }
    var handleAreaHeight: CGFloat { max(12, scaled(PickyHUDExpansion.dockHandleAreaHeight)) }
    var handleIdleWidth: CGFloat { max(16, scaled(18)) }
    var handleActiveWidth: CGFloat { max(22, scaled(24)) }
    var handleHeight: CGFloat { max(2.5, scaled(3)) }
    var plusFontSize: CGFloat { max(11, scaled(13)) }
    var collapsedDashWidth: CGFloat { max(16, scaled(18)) }
    var collapsedDashHeight: CGFloat { max(1, 1 * scale) }
    var statusDotSide: CGFloat { max(6, scaled(8)) }
    var archiveRingSide: CGFloat { max(36, scaled(42)) }
    var archiveBadgeSide: CGFloat { max(12, scaled(14)) }
    /// Width of the dock-icon hover preview card. Scales together with the dock
    /// rail itself so the preview never looks oversized next to a Small dock or
    /// undersized next to a Large dock. Lower bound keeps the title/status row
    /// readable when the preset is shrunk to Small.
    var previewCardWidth: CGFloat { max(200, scaled(238)) }

    private func scaled(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded(.toNearestOrAwayFromZero)
    }
}

enum PickyHUDDockLayout {
    static let visibleSessionLimit = 12
    static let panelWidth: CGFloat = 540
    static let detailWidth: CGFloat = 446
    static let detailHorizontalPadding: CGFloat = 12
    static var detailContentWidth: CGFloat { max(0, detailWidth - (detailHorizontalPadding * 2)) }
    static let railWidth: CGFloat = 62
    static let panelGap: CGFloat = 10
    static let screenMargin: CGFloat = 8
    /// Distance kept between the dock capsule and the screen edge.
    /// Tighter than `screenMargin` so the dock visually anchors to the bezel.
    static let dockEdgeMargin: CGFloat = 4
    /// Backward-compatible name for callers/tests that describe the default right edge.
    static let dockRightEdgeMargin: CGFloat = dockEdgeMargin
    static let dockLeftEdgeMargin: CGFloat = dockEdgeMargin
    static let closeDelay: TimeInterval = 0.4
    static let closeDelayNanoseconds: UInt64 = 400_000_000
    static let defaultGitSectionExpanded = true
    static let addSlotButtonSide: CGFloat = 36
    static let collapsedAddSlotVisualHeight: CGFloat = 14

    static var addSlotCollapsedExpansionReserve: CGFloat {
        PickyHUDDockMetrics.medium.addSlotCollapsedExpansionReserve
    }

    static func addSlotFrameHeight(isExpanded: Bool, metrics: PickyHUDDockMetrics = .medium) -> CGFloat {
        isExpanded ? metrics.addSlotButtonSide : metrics.collapsedAddSlotVisualHeight
    }

    static func dockRailSessionsHeight(sessionCount: Int, isAddSlotExpanded: Bool, metrics: PickyHUDDockMetrics = .medium) -> CGFloat {
        guard sessionCount > 0 else { return metrics.addSlotButtonSide }
        let sessionRowsHeight = CGFloat(sessionCount) * metrics.sessionTileHeight
        let sessionGapsHeight = CGFloat(max(0, sessionCount - 1)) * metrics.sessionSpacing
        return sessionRowsHeight
            + sessionGapsHeight
            + metrics.addSlotTopPadding
            + addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
    }

    static func dockRailHeight(sessionCount: Int, isAddSlotExpanded: Bool, metrics: PickyHUDDockMetrics = .medium) -> CGFloat {
        metrics.topPadding
            + metrics.handleAreaHeight
            + 2
            + dockRailSessionsHeight(sessionCount: sessionCount, isAddSlotExpanded: isAddSlotExpanded, metrics: metrics)
            + metrics.bottomPadding
    }

    static func contentSizeReservingAddSlotExpansion(
        measuredSize: CGSize,
        activeSessionID: String?,
        hasVisibleSessions: Bool,
        isAddSlotExpanded: Bool,
        metrics: PickyHUDDockMetrics = .medium
    ) -> CGSize {
        guard activeSessionID == nil,
              hasVisibleSessions,
              !isAddSlotExpanded
        else { return measuredSize }

        return CGSize(
            width: measuredSize.width,
            height: measuredSize.height + metrics.addSlotCollapsedExpansionReserve
        )
    }

    static func activeSessionID(visibleIDs: [String], held: PickyHUDDockHold?, previewID: String?) -> String? {
        if let held, visibleIDs.contains(held.sessionID) { return held.sessionID }
        if let previewID, visibleIDs.contains(previewID) { return previewID }
        return nil
    }

    static func previewSessionID(hoveredID: String?, heldID: String?) -> String? {
        heldID == nil ? hoveredID : nil
    }

    static func previewSessionIDAfterDockHover(current: String?, sessionID: String) -> String? {
        sessionID
    }

    static func previewSessionIDAfterCloseTimeout(current: String?, isDockHovered: Bool) -> String? {
        isDockHovered ? current : nil
    }

    static func heldSessionAfterCloseTimeout(current: PickyHUDDockHold?, isHUDHovered: Bool) -> PickyHUDDockHold? {
        current
    }

    static func heldSessionAfterClick(current: PickyHUDDockHold?, clicked: String) -> PickyHUDDockHold? {
        switch current {
        case .open(clicked):
            return nil
        case .open, nil:
            return .open(clicked)
        }
    }

    static func numberShortcutForSessionIndex(_ index: Int) -> Int? {
        guard index >= 0, index < 9 else { return nil }
        return index + 1
    }

    static func sessionIDForNumberShortcut(visibleIDs: [String], number: Int) -> String? {
        guard number >= 1, number <= visibleIDs.count else { return nil }
        return visibleIDs[number - 1]
    }

    static func heldSessionAfterNumberShortcut(current: PickyHUDDockHold?, visibleIDs: [String], number: Int) -> PickyHUDDockHold? {
        guard let targetID = sessionIDForNumberShortcut(visibleIDs: visibleIDs, number: number) else { return current }
        return heldSessionAfterClick(current: current, clicked: targetID)
    }

    static func heldSessionAfterCycleShortcut(current: PickyHUDDockHold?, visibleIDs: [String], direction: Int) -> PickyHUDDockHold? {
        guard !visibleIDs.isEmpty else { return current }
        let currentIndex = current.flatMap { held in visibleIDs.firstIndex(of: held.sessionID) }
        let baseIndex = currentIndex ?? (direction >= 0 ? -1 : 0)
        let nextIndex = (baseIndex + direction + visibleIDs.count) % visibleIDs.count
        return .open(visibleIDs[nextIndex])
    }

    static func gitSectionExpansion(sessionID: String, storedValues: [String: Bool]) -> Bool {
        storedValues[sessionID] ?? defaultGitSectionExpanded
    }

    static func gitSectionExpansionValues(_ storedValues: [String: Bool], setting isExpanded: Bool, for sessionID: String) -> [String: Bool] {
        var updatedValues = storedValues
        updatedValues[sessionID] = isExpanded
        return updatedValues
    }

    static func centeredPanelY(visibleFrame: CGRect, targetHeight: CGFloat) -> CGFloat {
        let minimumY = visibleFrame.minY + screenMargin
        let maximumY = max(minimumY, visibleFrame.maxY - screenMargin - targetHeight)
        let centeredY = visibleFrame.midY - (targetHeight / 2)
        return min(max(centeredY, minimumY), maximumY)
    }

    static func panelX(visibleFrame: CGRect, panelWidth: CGFloat, dockSide: PickyHUDDockSide, xOffset: CGFloat = 0) -> CGFloat {
        // Mirror the Y-axis fix in `dockTopAnchoredPointAlignedPanelTopY`: AppKit
        // normalizes window frames to whole-point bounds. If `xOffset` ever lands
        // on a fractional value (mouse drag, clamping math) NSPanel would round
        // origin.x differently from one `setFrame` call to the next, producing
        // a 1pt sideways jitter as the panel is resized between sessions.
        // Pin the panel's leading edge to a deterministic whole-point value so
        // the dock cannot drift while the card grows or shrinks.
        let raw: CGFloat
        switch dockSide {
        case .right:
            raw = visibleFrame.maxX - panelWidth - dockRightEdgeMargin + xOffset
        case .left:
            raw = visibleFrame.minX + dockLeftEdgeMargin + xOffset
        case .top, .bottom:
            // Vertical-only helper; horizontal callers use `horizontalPanelX`.
            // Fall back to the `.right` placement so accidental misuse stays on
            // screen instead of producing NaN.
            raw = visibleFrame.maxX - panelWidth - dockRightEdgeMargin + xOffset
        }
        return raw.rounded(.toNearestOrEven)
    }

    static func clampedPanelX(visibleFrame: CGRect, panelWidth: CGFloat, dockSide: PickyHUDDockSide, xOffset: CGFloat = 0) -> CGFloat {
        let safeOffset = clampedXOffset(
            xOffset,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: dockSide
        )
        return panelX(
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: dockSide,
            xOffset: safeOffset
        )
    }

    static func dockRailCenterX(
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        dockSide: PickyHUDDockSide,
        xOffset: CGFloat = 0,
        dockRailWidth: CGFloat = railWidth
    ) -> CGFloat {
        let x = panelX(
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: dockSide,
            xOffset: xOffset
        )
        switch dockSide {
        case .right, .top, .bottom:
            return x + panelWidth - PickyHUDExpansion.outerPadding - (dockRailWidth / 2)
        case .left:
            return x + PickyHUDExpansion.outerPadding + (dockRailWidth / 2)
        }
    }

    static let dockSideSnapLeftThreshold: CGFloat = 0.40
    static let dockSideSnapRightThreshold: CGFloat = 0.60

    static func dockSide(
        forDockRailCenterX dockRailCenterX: CGFloat,
        visibleFrame: CGRect,
        currentSide: PickyHUDDockSide
    ) -> PickyHUDDockSide {
        guard visibleFrame.width > 0 else { return currentSide }
        let relativeX = (dockRailCenterX - visibleFrame.minX) / visibleFrame.width
        if relativeX < dockSideSnapLeftThreshold { return .left }
        if relativeX > dockSideSnapRightThreshold { return .right }
        return currentSide
    }

    static func xOffset(
        forDockRailCenterX dockRailCenterX: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        dockSide: PickyHUDDockSide,
        dockRailWidth: CGFloat = railWidth
    ) -> CGFloat {
        let naturalPanelX = panelX(
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: dockSide
        )
        let naturalDockRailCenterX: CGFloat
        switch dockSide {
        case .right, .top, .bottom:
            naturalDockRailCenterX = naturalPanelX + panelWidth - PickyHUDExpansion.outerPadding - (dockRailWidth / 2)
        case .left:
            naturalDockRailCenterX = naturalPanelX + PickyHUDExpansion.outerPadding + (dockRailWidth / 2)
        }
        return clampedXOffset(
            dockRailCenterX - naturalDockRailCenterX,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: dockSide,
            dockRailWidth: dockRailWidth
        )
    }

    static func horizontalPanelX(visibleFrame: CGRect, panelWidth: CGFloat, xOffset: CGFloat = 0) -> CGFloat {
        let safeOffset = clampedHorizontalXOffset(xOffset, visibleFrame: visibleFrame, panelWidth: panelWidth)
        let raw = visibleFrame.midX - (panelWidth / 2) + safeOffset
        return raw.rounded(.toNearestOrEven)
    }

    static func clampedHorizontalXOffset(_ xOffset: CGFloat, visibleFrame: CGRect, panelWidth: CGFloat) -> CGFloat {
        let centeredX = visibleFrame.midX - (panelWidth / 2)
        let minX = visibleFrame.minX + screenMargin
        let maxX = visibleFrame.maxX - screenMargin - panelWidth
        guard maxX >= minX else { return 0 }
        return min(maxX - centeredX, max(minX - centeredX, xOffset))
    }

    static func horizontalPanelY(visibleFrame: CGRect, targetHeight: CGFloat, dockSide: PickyHUDDockSide) -> CGFloat {
        switch dockSide {
        case .top:
            return (visibleFrame.maxY - targetHeight - dockEdgeMargin).rounded(.toNearestOrEven)
        case .bottom:
            return (visibleFrame.minY + dockEdgeMargin).rounded(.toNearestOrEven)
        case .left, .right:
            return dockTopAnchoredPointAlignedPanelY(
                visibleFrame: visibleFrame,
                targetHeight: targetHeight,
                topPaddingFromContentTop: dockBodyTopOffsetFallback,
                anchorPercent: PickySettings.defaultDockTopAnchorPercent
            )
        }
    }

    private static var dockBodyTopOffsetFallback: CGFloat {
        PickyHUDExpansion.dockBodyTopOffsetFromContentTop
    }

    static let dockSideSnapTopThreshold: CGFloat = 0.60
    static let dockSideSnapBottomThreshold: CGFloat = 0.40

    static func horizontalDockSide(
        forDockRailCenterY dockRailCenterY: CGFloat,
        visibleFrame: CGRect,
        currentSide: PickyHUDDockSide
    ) -> PickyHUDDockSide {
        guard visibleFrame.height > 0 else { return currentSide }
        let relativeY = (dockRailCenterY - visibleFrame.minY) / visibleFrame.height
        if relativeY > dockSideSnapTopThreshold { return .top }
        if relativeY < dockSideSnapBottomThreshold { return .bottom }
        return currentSide
    }

    /// Maximum number of points the dock capsule may slide past the screen edge
    /// in either direction. Half the dock rail width keeps half of the capsule
    /// visible so the handle is always grabbable.
    static let dockOverhangLimit: CGFloat = (railWidth / 2).rounded(.down)

    static func dockOverhangLimit(forRailWidth dockRailWidth: CGFloat) -> CGFloat {
        (dockRailWidth / 2).rounded(.down)
    }

    /// Clamp an X offset so the dock can move inward freely but only slide up to
    /// `dockOverhangLimit` past the screen edge. The dock capsule itself never
    /// fully disappears, but users can tuck it partially off-screen if they want.
    static func clampedXOffset(
        _ xOffset: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        dockSide: PickyHUDDockSide,
        dockRailWidth: CGFloat = railWidth
    ) -> CGFloat {
        let overhangLimit = dockOverhangLimit(forRailWidth: dockRailWidth)
        switch dockSide {
        case .right, .top, .bottom:
            let minX = visibleFrame.minX + screenMargin
            let naturalX = visibleFrame.maxX - panelWidth - dockRightEdgeMargin
            let maxShiftLeft = naturalX - minX
            return max(-maxShiftLeft, min(overhangLimit, xOffset))
        case .left:
            let maxX = visibleFrame.maxX - screenMargin - panelWidth
            let naturalX = visibleFrame.minX + dockLeftEdgeMargin
            let maxShiftRight = maxX - naturalX
            return min(maxShiftRight, max(-overhangLimit, xOffset))
        }
    }

    // MARK: - Dock-top anchored placement

    /// Screen Y of the dock's top edge for a given anchor percent (2–70% from the top of
    /// `visibleFrame`). Returned in NSPanel screen coords (bottom-up).
    static func dockTopScreenY(visibleFrame: CGRect, anchorPercent: Double) -> CGFloat {
        let pct = PickySettings.clampedDockTopAnchorPercent(anchorPercent)
        return visibleFrame.maxY - visibleFrame.height * (pct / 100.0)
    }

    /// Panel origin Y (NSPanel screen coords, bottom-up) so that the dock's top edge
    /// sits at `dockTopScreenY`. `topPaddingFromContentTop` is the SwiftUI top-down
    /// distance from the panel content's top to the dock rail's top edge — with
    /// `HStack(alignment: .top)` and `dockShadowInsets` wrapping the HStack, that
    /// distance equals the top inset (`PickyHUDExpansion.dockShadowTopPadding`).
    ///
    /// Callers should cap `targetHeight` at `dockTopAnchoredMaxPanelHeight(...)` first
    /// so the formula never has to clamp at the visible-frame floor (which would push
    /// the dock upward, defeating the anchoring guarantee).
    static func dockTopAnchoredPanelY(
        visibleFrame: CGRect,
        targetHeight: CGFloat,
        topPaddingFromContentTop: CGFloat,
        anchorPercent: Double
    ) -> CGFloat {
        let dockTopY = dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: anchorPercent)
        let originY = dockTopY - targetHeight + topPaddingFromContentTop
        let minimumY = visibleFrame.minY + screenMargin
        return max(originY, minimumY)
    }

    /// Point-aligned NSPanel top Y for dock-top anchoring. AppKit normalizes window
    /// frames to whole-point bounds; if the fractional part sometimes lives in
    /// `origin.y` and sometimes in `height`, the rendered dock can differ by 1pt when
    /// switching between short and height-capped HUD cards. Anchor the panel's top to
    /// one deterministic whole-point value first, then derive origin from that top.
    static func dockTopAnchoredPointAlignedPanelTopY(
        visibleFrame: CGRect,
        topPaddingFromContentTop: CGFloat,
        anchorPercent: Double
    ) -> CGFloat {
        let dockTopY = dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: anchorPercent)
        return (dockTopY + topPaddingFromContentTop).rounded(.down)
    }

    /// Point-aligned panel origin Y for a point-aligned `targetHeight`. The rendered
    /// dock top becomes `dockTopAnchoredPointAlignedPanelTopY - topPaddingFromContentTop`
    /// for every card height, so hover-switching sessions cannot move the dock by the
    /// AppKit frame-rounding remainder.
    static func dockTopAnchoredPointAlignedPanelY(
        visibleFrame: CGRect,
        targetHeight: CGFloat,
        topPaddingFromContentTop: CGFloat,
        anchorPercent: Double
    ) -> CGFloat {
        let panelTopY = dockTopAnchoredPointAlignedPanelTopY(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPaddingFromContentTop,
            anchorPercent: anchorPercent
        )
        let minimumY = (visibleFrame.minY + screenMargin).rounded(.up)
        return max(panelTopY - targetHeight, minimumY)
    }

    /// Largest panel height that still lets `dockTopAnchoredPanelY` keep the dock at
    /// `dockTopScreenY` without falling through `visibleFrame.minY + screenMargin`.
    /// The conversation list inside the card has its own ScrollView so anything
    /// requesting more height scrolls in place rather than overflowing the screen.
    static func dockTopAnchoredMaxPanelHeight(
        visibleFrame: CGRect,
        topPaddingFromContentTop: CGFloat,
        anchorPercent: Double
    ) -> CGFloat {
        let dockTopY = dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: anchorPercent)
        let bottomFloor = visibleFrame.minY + screenMargin
        return max(0, dockTopY - bottomFloor + topPaddingFromContentTop)
    }

    /// Whole-point version of `dockTopAnchoredMaxPanelHeight`, matching the frame that
    /// AppKit will actually keep after `NSPanel.setFrame`. Use this for live panel/card
    /// caps so the measured HUD height and the window's final integer frame agree.
    static func dockTopAnchoredPointAlignedMaxPanelHeight(
        visibleFrame: CGRect,
        topPaddingFromContentTop: CGFloat,
        anchorPercent: Double
    ) -> CGFloat {
        let panelTopY = dockTopAnchoredPointAlignedPanelTopY(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPaddingFromContentTop,
            anchorPercent: anchorPercent
        )
        let bottomFloor = (visibleFrame.minY + screenMargin).rounded(.up)
        return max(0, panelTopY - bottomFloor)
    }
}

enum PickyHUDExpandedContentPolicy {
    static let showsRecentLog = false
    static let summaryLineLimit: Int? = nil

    static func showsSummary(for status: PickySessionStatus) -> Bool {
        switch status {
        case .queued, .running, .waiting_for_input:
            return false
        case .blocked, .completed, .failed, .cancelled:
            return true
        }
    }
}

enum PickyHUDSummaryEventPolicy {
    static func label(for status: PickySessionStatus, hasReportArtifact: Bool) -> String {
        switch status {
        case .completed: return hasReportArtifact ? "Report ready" : "Result"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .blocked: return "Blocked"
        case .waiting_for_input: return "Awaiting input"
        case .running, .queued: return "Update"
        }
    }

    static func time(for status: PickySessionStatus, summaryElapsed: String) -> String {
        switch status {
        case .running, .queued: return "now"
        default: return summaryElapsed
        }
    }
}

enum PickyHUDCurrentWorkPolicy {
    static func runningDescription(activeTool: PickyToolActivity?, thinkingPreview: String?) -> String? {
        var lines = [String]()

        if let activeTool {
            lines.append("Tool: \(activeTool.name)")
        }

        let trimmedThinkingPreview = thinkingPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedThinkingPreview.isEmpty {
            lines.append("Thinking: \(trimmedThinkingPreview)")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
