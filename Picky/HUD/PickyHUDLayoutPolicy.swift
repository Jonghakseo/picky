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
    static let outerPadding: CGFloat = 16
    static let dockShadowOpacity = 0.20
    static let dockShadowRadius: CGFloat = 12
    static let dockShadowYOffset: CGFloat = 10
    // SwiftUI shadows are drawn outside layout bounds. Give the transparent NSPanel
    // explicit chrome bleed so the dock's blur tail is not clipped at the hosting
    // view edge. Vertical bleed is asymmetric because the main shadow is offset down.
    static let dockShadowHorizontalExtraBleed: CGFloat = 4
    static let dockShadowVerticalExtraBleed: CGFloat = 8
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
    static let dockTightShadowOpacity = 0.10
    static let dockTightShadowRadius: CGFloat = 3
    static let dockTightShadowYOffset: CGFloat = 1
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
    case pinned(String)

    var sessionID: String {
        switch self {
        case let .open(sessionID), let .pinned(sessionID):
            return sessionID
        }
    }

    func isOpen(sessionID: String) -> Bool {
        self == .open(sessionID)
    }

    func isPinned(sessionID: String) -> Bool {
        self == .pinned(sessionID)
    }
}

enum PickyHUDDockLayout {
    static let visibleSessionLimit = 12
    static let panelWidth: CGFloat = 540
    static let detailWidth: CGFloat = 446
    static let detailHorizontalPadding: CGFloat = 12
    static var detailContentWidth: CGFloat { max(0, detailWidth - (detailHorizontalPadding * 2)) }
    static let railWidth: CGFloat = 50
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

    static func activeSessionID(visibleIDs: [String], held: PickyHUDDockHold?, previewID: String?) -> String? {
        if let previewID, visibleIDs.contains(previewID) { return previewID }
        if let held, visibleIDs.contains(held.sessionID) { return held.sessionID }
        return nil
    }

    static func previewSessionID(hoveredID: String?, heldID: String?) -> String? {
        hoveredID ?? heldID
    }

    static func previewSessionIDAfterDockHover(current: String?, sessionID: String, pinnedID: String?) -> String? {
        sessionID
    }

    static func previewSessionIDAfterCloseTimeout(current: String?, pinnedID: String?, isDockHovered: Bool) -> String? {
        isDockHovered ? current : nil
    }

    static func heldSessionAfterCloseTimeout(current: PickyHUDDockHold?, isHUDHovered: Bool) -> PickyHUDDockHold? {
        switch current {
        case .open:
            return isHUDHovered ? current : nil
        case .pinned, nil:
            return current
        }
    }

    static func heldSessionAfterClick(current: PickyHUDDockHold?, clicked: String) -> PickyHUDDockHold? {
        switch current {
        case .open(clicked), .pinned(clicked):
            return nil
        case .open, .pinned, nil:
            return .open(clicked)
        }
    }

    static func heldSessionAfterDoubleClick(current: PickyHUDDockHold?, doubleClicked: String) -> PickyHUDDockHold? {
        switch current {
        case .pinned(doubleClicked):
            return nil
        case .open, .pinned, nil:
            return .pinned(doubleClicked)
        }
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
        xOffset: CGFloat = 0
    ) -> CGFloat {
        let x = panelX(
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: dockSide,
            xOffset: xOffset
        )
        switch dockSide {
        case .right:
            return x + panelWidth - PickyHUDExpansion.outerPadding - (railWidth / 2)
        case .left:
            return x + PickyHUDExpansion.outerPadding + (railWidth / 2)
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
        dockSide: PickyHUDDockSide
    ) -> CGFloat {
        let naturalPanelX = panelX(
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: dockSide
        )
        let naturalDockRailCenterX: CGFloat
        switch dockSide {
        case .right:
            naturalDockRailCenterX = naturalPanelX + panelWidth - PickyHUDExpansion.outerPadding - (railWidth / 2)
        case .left:
            naturalDockRailCenterX = naturalPanelX + PickyHUDExpansion.outerPadding + (railWidth / 2)
        }
        return clampedXOffset(
            dockRailCenterX - naturalDockRailCenterX,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: dockSide
        )
    }

    /// Maximum number of points the dock capsule may slide past the screen edge
    /// in either direction. Half the dock rail width keeps half of the capsule
    /// visible so the handle is always grabbable.
    static let dockOverhangLimit: CGFloat = (railWidth / 2).rounded(.down)

    /// Clamp an X offset so the dock can move inward freely but only slide up to
    /// `dockOverhangLimit` past the screen edge. The dock capsule itself never
    /// fully disappears, but users can tuck it partially off-screen if they want.
    static func clampedXOffset(
        _ xOffset: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        dockSide: PickyHUDDockSide
    ) -> CGFloat {
        switch dockSide {
        case .right:
            let minX = visibleFrame.minX + screenMargin
            let naturalX = visibleFrame.maxX - panelWidth - dockRightEdgeMargin
            let maxShiftLeft = naturalX - minX
            return max(-maxShiftLeft, min(dockOverhangLimit, xOffset))
        case .left:
            let maxX = visibleFrame.maxX - screenMargin - panelWidth
            let naturalX = visibleFrame.minX + dockLeftEdgeMargin
            let maxShiftRight = maxX - naturalX
            return min(maxShiftRight, max(-dockOverhangLimit, xOffset))
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
