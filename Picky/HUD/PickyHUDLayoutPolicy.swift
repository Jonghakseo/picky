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
    static let outerPadding: CGFloat = 14
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
}

enum PickyHUDDockLayout {
    static let visibleSessionLimit = 6
    static let panelWidth: CGFloat = 540
    static let detailWidth: CGFloat = 446
    static let railWidth: CGFloat = 56
    static let panelGap: CGFloat = 10
    static let screenMargin: CGFloat = 8
    static let closeDelay: TimeInterval = 0.4
    static let closeDelayNanoseconds: UInt64 = 400_000_000

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
