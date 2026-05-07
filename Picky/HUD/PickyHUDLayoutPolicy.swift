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
    static let outerPadding: CGFloat = 8
    static let dockShadowOpacity = 0.30
    static let dockShadowRadius: CGFloat = 18
    static let dockShadowYOffset: CGFloat = 10
    static let dockShadowExtraBleed: CGFloat = 4
    static var dockShadowVerticalPadding: CGFloat {
        dockShadowRadius + abs(dockShadowYOffset) + dockShadowExtraBleed
    }
    static let dockTightShadowOpacity = 0.10
    static let dockTightShadowRadius: CGFloat = 3
    static let dockTightShadowYOffset: CGFloat = 1
    static let cardShadowOpacity = 0.12
    static let cardShadowRadius: CGFloat = 8
    static let cardShadowYOffset: CGFloat = 4
    /// Drag handle visual height plus its hit-area padding inside
    /// `PickyHUDDockRailView.dockAnchorHandle`. Combined with the VStack spacing below
    /// it (`dockHandleToBodySpacing`) and the outer vertical padding, this is how far
    /// the dock CAPSULE's top edge sits below the panel content top.
    static let dockHandleAreaHeight: CGFloat = 14
    /// VStack spacing between the drag handle and the dock capsule.
    static let dockHandleToBodySpacing: CGFloat = 4
    /// Distance from the panel content's top edge (in SwiftUI top-down coords) down to
    /// the dock CAPSULE's top edge. Equals `dockShadowVerticalPadding + handle area
    /// height + handle→body spacing`. The overlay manager uses this as
    /// `topPaddingFromContentTop` so `dockTopScreenY` lands exactly on the visible
    /// dock capsule top, not on the (smaller, less obvious) handle's top edge.
    static var dockBodyTopOffsetFromContentTop: CGFloat {
        dockShadowVerticalPadding + dockHandleAreaHeight + dockHandleToBodySpacing
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

enum PickyHUDDockLayout {
    static let visibleSessionLimit = 12
    static let panelWidth: CGFloat = 540
    static let detailWidth: CGFloat = 446
    static let detailHorizontalPadding: CGFloat = 12
    static var detailContentWidth: CGFloat { max(0, detailWidth - (detailHorizontalPadding * 2)) }
    static let railWidth: CGFloat = 56
    static let panelGap: CGFloat = 10
    static let screenMargin: CGFloat = 8
    /// Distance kept between the dock capsule and the screen's right edge.
    /// Tighter than `screenMargin` so the dock visually anchors to the bezel.
    static let dockRightEdgeMargin: CGFloat = 4
    static let closeDelay: TimeInterval = 0.4
    static let closeDelayNanoseconds: UInt64 = 400_000_000
    static let defaultGitSectionExpanded = true

    static func activeSessionID(visibleIDs: [String], pinnedID: String?, previewID: String?) -> String? {
        if let previewID, visibleIDs.contains(previewID) { return previewID }
        if let pinnedID, visibleIDs.contains(pinnedID) { return pinnedID }
        return nil
    }

    static func previewSessionIDAfterDockHover(current: String?, sessionID: String, pinnedID: String?) -> String? {
        sessionID
    }

    static func previewSessionIDAfterCloseTimeout(current: String?, pinnedID: String?, isHUDHovered: Bool) -> String? {
        isHUDHovered ? current : nil
    }

    static func pinnedSessionIDAfterClick(current: String?, clicked: String) -> String? {
        current == clicked ? nil : clicked
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
    /// `HStack(alignment: .top)` and `.padding(.vertical, P)` wrapping the HStack, that
    /// distance equals `P` (= `PickyHUDExpansion.dockShadowVerticalPadding`).
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
