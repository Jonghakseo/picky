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
        if let pinnedID, visibleIDs.contains(pinnedID) { return pinnedID }
        if let previewID, visibleIDs.contains(previewID) { return previewID }
        return nil
    }

    static func previewSessionIDAfterDockHover(current: String?, sessionID: String, pinnedID: String?) -> String? {
        pinnedID == nil ? sessionID : current
    }

    static func previewSessionIDAfterCloseTimeout(current: String?, pinnedID: String?, isHUDHovered: Bool) -> String? {
        pinnedID == nil && !isHUDHovered ? nil : current
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
