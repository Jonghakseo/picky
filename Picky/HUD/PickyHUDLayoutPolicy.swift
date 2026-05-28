//
//  PickyHUDLayoutPolicy.swift
//  Picky
//
//  Pure HUD expansion and content visibility policy.
//

import SwiftUI

private struct PickyHUDDetailWidthEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = PickyHUDDockLayout.detailWidth
}

extension EnvironmentValues {
    var pickyHUDDetailWidth: CGFloat {
        get { self[PickyHUDDetailWidthEnvironmentKey.self] }
        set { self[PickyHUDDetailWidthEnvironmentKey.self] = newValue }
    }
}

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

enum PickyHUDDockLabelPolicy {
    private static let displayUnitLimit = 6.0

    static func compactLabel(_ string: String) -> String {
        let normalized = string
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Pickle" }

        var usedUnits = 0.0
        var label = ""
        for character in normalized {
            let nextUnits = usedUnits + displayWeight(for: character)
            guard nextUnits <= displayUnitLimit else { break }
            label.append(character)
            usedUnits = nextUnits
        }
        return label.isEmpty ? String(normalized.prefix(1)) : label
    }

    static func containsHangul(_ string: String) -> Bool {
        string.unicodeScalars.contains { isHangul($0.value) }
    }

    private static func displayWeight(for character: Character) -> Double {
        character.unicodeScalars.contains { isWideDisplayScalar($0.value) } ? 1.5 : 1.0
    }

    private static func isWideDisplayScalar(_ value: UInt32) -> Bool {
        isHangul(value)
            || (0x2E80...0x2EFF ~= value) // CJK radicals supplement
            || (0x3000...0x303F ~= value) // CJK symbols and punctuation
            || (0x3040...0x30FF ~= value) // Hiragana / Katakana
            || (0x31F0...0x31FF ~= value) // Katakana phonetic extensions
            || (0x3400...0x4DBF ~= value) // CJK extension A
            || (0x4E00...0x9FFF ~= value) // CJK unified ideographs
            || (0xF900...0xFAFF ~= value) // CJK compatibility ideographs
            || (0xFF01...0xFF60 ~= value) // fullwidth ASCII variants
            || (0xFFE0...0xFFE6 ~= value) // fullwidth symbols
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        (0x1100...0x11FF ~= value) // Hangul Jamo
            || (0x3130...0x318F ~= value) // Hangul compatibility Jamo
            || (0xAC00...0xD7A3 ~= value) // Hangul syllables
    }
}

enum PickyHUDDockLayout {
    static let visibleSessionLimit = 12
    static let panelWidth: CGFloat = 540
    static let detailWidth: CGFloat = 446
    static let detailHorizontalPadding: CGFloat = 12
    static var detailContentWidth: CGFloat { detailContentWidth(for: detailWidth) }
    static func detailContentWidth(for detailWidth: CGFloat) -> CGFloat {
        max(0, detailWidth - (detailHorizontalPadding * 2))
    }
    static let extendedTerminalHeight: CGFloat = 240
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

    static func fullscreenDockControlSide(metrics: PickyHUDDockMetrics = .medium) -> CGFloat {
        max(22, metrics.addSlotButtonSide * 0.62)
    }

    static func fullscreenDockControlLength(metrics: PickyHUDDockMetrics = .medium) -> CGFloat {
        fullscreenDockControlSide(metrics: metrics) + 2
    }

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

    /// Long-axis (X) length of the dock rail in horizontal orientation.
    /// Mirrors `dockRailHeight` but uses symmetric leading/trailing padding
    /// (small `topPadding` on both sides instead of vertical's larger
    /// `bottomPadding`) and drops `addSlotTopPadding` between the last
    /// session and the collapsed `+` slot — horizontal needs less internal
    /// breathing room than vertical because the dock is short on the cross
    /// axis and any extra padding reads as wasted space. Includes the
    /// fullscreen workspace control so the owning NSPanel width and drag clamp
    /// match the rail actually rendered by `PickyHUDDockRailView`.
    static func horizontalDockRailLength(
        sessionCount: Int,
        isAddSlotExpanded: Bool,
        metrics: PickyHUDDockMetrics = .medium
    ) -> CGFloat {
        let sessionsAndSlot: CGFloat = {
            guard sessionCount > 0 else { return metrics.addSlotButtonSide }
            let sessionRows = CGFloat(sessionCount) * metrics.sessionTileWidth
            let sessionGaps = CGFloat(max(0, sessionCount - 1)) * metrics.sessionSpacing
            // 2pt parent-HStack spacing between the sessions row and the slot.
            return sessionRows
                + sessionGaps
                + 2
                + addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
        }()
        return metrics.topPadding
            + metrics.handleAreaHeight
            + 2
            + fullscreenDockControlLength(metrics: metrics)
            + sessionsAndSlot
            + metrics.topPadding
    }

    /// Worst-case horizontal overflow of the hover-preview card past an edge
    /// dock icon in horizontal mode. The mini preview is centered on the icon
    /// (`PickyHUDView.miniPreviewOffset` x = 0 for horizontal docks), so each
    /// side may bleed up to `previewCardWidth/2 - sessionTileWidth/2` beyond
    /// the rail's leading/trailing edge. The HUD reserves this much horizontal
    /// slack around the rail so the NSPanel content view encloses the preview
    /// instead of clipping it.
    static func miniPreviewHorizontalReserve(metrics: PickyHUDDockMetrics) -> CGFloat {
        max(0, (metrics.previewCardWidth - metrics.sessionTileWidth) / 2)
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

    static func panelWidth(
        cardWidth: CGFloat,
        dockSide: PickyHUDDockSide,
        sessionCount: Int,
        isAddSlotExpanded: Bool,
        metrics: PickyHUDDockMetrics = .medium
    ) -> CGFloat {
        switch dockSide.orientation {
        case .vertical:
            return cardWidth + panelGap + metrics.railWidth + (PickyHUDExpansion.dockShadowHorizontalPadding * 2)
        case .horizontal:
            let railLength = horizontalDockRailLength(
                sessionCount: sessionCount,
                isAddSlotExpanded: isAddSlotExpanded,
                metrics: metrics
            ) + (miniPreviewHorizontalReserve(metrics: metrics) * 2)
            return max(cardWidth, railLength) + (PickyHUDExpansion.dockShadowHorizontalPadding * 2)
        }
    }

    static func resizeStartCardSize(
        storedSize: PickyHUDCardSize?,
        measuredSize: CGSize?,
        maxHeight: CGFloat = PickyHUDCardSize.heightRange.upperBound
    ) -> PickyHUDCardSize? {
        if let storedSize {
            return storedSize.clamped(maxHeight: maxHeight)
        }
        guard let measuredSize, measuredSize.width > 0, measuredSize.height > 0 else { return nil }
        return PickyHUDCardSize.clamped(
            width: measuredSize.width,
            height: measuredSize.height,
            maxHeight: maxHeight
        )
    }

    static func resizeStartCardSizes(
        storedSizes: [String: PickyHUDCardSize],
        displayKey: String,
        measuredSize: CGSize?,
        maxHeight: CGFloat = PickyHUDCardSize.heightRange.upperBound
    ) -> [String: PickyHUDCardSize] {
        var startSizes = storedSizes
        if let storedSize = startSizes[displayKey] {
            startSizes[displayKey] = storedSize.clamped(maxHeight: maxHeight)
            return startSizes
        }
        if let measuredStartSize = resizeStartCardSize(
            storedSize: nil,
            measuredSize: measuredSize,
            maxHeight: maxHeight
        ) {
            startSizes[displayKey] = measuredStartSize
        }
        return startSizes
    }

    static func resizedCardSize(
        from startSize: PickyHUDCardSize,
        delta: CGPoint,
        dockSide: PickyHUDDockSide,
        maxWidth: CGFloat = PickyHUDCardSize.widthRange.upperBound,
        maxHeight: CGFloat = PickyHUDCardSize.heightRange.upperBound
    ) -> PickyHUDCardSize {
        let rawWidth: CGFloat
        let rawHeight: CGFloat
        switch dockSide {
        case .right:
            rawWidth = startSize.width - delta.x
            rawHeight = startSize.height - delta.y
        case .left, .top:
            rawWidth = startSize.width + delta.x
            rawHeight = startSize.height - delta.y
        case .bottom:
            rawWidth = startSize.width + delta.x
            rawHeight = startSize.height + delta.y
        }
        return PickyHUDCardSize.clamped(
            width: rawWidth,
            height: rawHeight,
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
    }

    static func activeSessionID(visibleIDs: [String], held: PickyHUDDockHold?, previewID: String?) -> String? {
        if let held, visibleIDs.contains(held.sessionID) { return held.sessionID }
        if let previewID, visibleIDs.contains(previewID) { return previewID }
        return nil
    }

    static func fullscreenTargetSessionID(visibleIDs: [String], held: PickyHUDDockHold?, hoverPreviewID: String?) -> String? {
        if let held, visibleIDs.contains(held.sessionID) { return held.sessionID }
        if let hoverPreviewID, visibleIDs.contains(hoverPreviewID) { return hoverPreviewID }
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

    static func manualAutoOpenResolution(pendingSessionID: String?, visibleIDs: [String]) -> PickyHUDDockHold? {
        guard let pendingSessionID, visibleIDs.contains(pendingSessionID) else { return nil }
        return .open(pendingSessionID)
    }

    static func requestedOpenResolution(pendingSessionID: String?, visibleIDs: [String]) -> PickyHUDDockHold? {
        guard let pendingSessionID, visibleIDs.contains(pendingSessionID) else { return nil }
        return .open(pendingSessionID)
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

    /// Clamp the horizontal mode's X-axis nudge so the dock rail — which
    /// sits centered inside the (much wider) panel — can slide all the way
    /// to either screen edge. The transparent panel is allowed to overhang
    /// the visible frame; only the dock's visible center is kept inside
    /// `visibleFrame` minus `screenMargin`. Pass `dockRailLength` so the
    /// clamp accounts for the dock's actual visible half-width; callers
    /// without it (e.g. older tests) get a conservative fallback.
    static func clampedHorizontalXOffset(
        _ xOffset: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        dockRailLength: CGFloat = 0
    ) -> CGFloat {
        let dockHalfLength = max(dockRailLength / 2, 0)
        let minDockCenter = visibleFrame.minX + screenMargin + dockHalfLength
        let maxDockCenter = visibleFrame.maxX - screenMargin - dockHalfLength
        guard maxDockCenter >= minDockCenter else { return 0 }
        // Panel center = visibleFrame.midX + xOffset (since panel is
        // centered at xOffset == 0). Dock center == panel center because
        // the dock is laid out with `.alignment(.center)` inside the panel,
        // so clamping the dock center is equivalent to clamping xOffset.
        let midX = visibleFrame.midX
        let minXOffset = minDockCenter - midX
        let maxXOffset = maxDockCenter - midX
        return min(maxXOffset, max(minXOffset, xOffset))
    }

    static func horizontalPanelY(
        visibleFrame: CGRect,
        targetHeight: CGFloat,
        dockSide: PickyHUDDockSide,
        yOffset: CGFloat = 0
    ) -> CGFloat {
        switch dockSide {
        case .top:
            // +yOffset = drag up (panel.y increases, dock peeks past the top edge).
            // -yOffset = drag down (dock slides into the screen toward center).
            return (visibleFrame.maxY - targetHeight - dockEdgeMargin + yOffset).rounded(.toNearestOrEven)
        case .bottom:
            // +yOffset = drag up (dock slides toward center).
            // -yOffset = drag down past the bottom edge for overhang.
            return (visibleFrame.minY + dockEdgeMargin + yOffset).rounded(.toNearestOrEven)
        case .left, .right:
            return dockTopAnchoredPointAlignedPanelY(
                visibleFrame: visibleFrame,
                targetHeight: targetHeight,
                topPaddingFromContentTop: dockBodyTopOffsetFallback,
                anchorPercent: PickySettings.defaultDockTopAnchorPercent
            )
        }
    }

    /// Cross-axis nudge clamp for horizontal mode. Mirrors `clampedXOffset`'s
    /// asymmetry: small overhang allowed past the anchored edge, free movement
    /// inward (the snap math then flips top<->bottom once the dock crosses the
    /// screen midline).
    static func clampedHorizontalYOffset(
        _ yOffset: CGFloat,
        visibleFrame: CGRect,
        panelHeight: CGFloat,
        dockSide: PickyHUDDockSide,
        dockRailHeight: CGFloat
    ) -> CGFloat {
        let overhangLimit = dockOverhangLimit(forRailWidth: dockRailHeight)
        switch dockSide {
        case .top:
            let minY = visibleFrame.minY + screenMargin
            let naturalY = visibleFrame.maxY - panelHeight - dockEdgeMargin
            // Drag down (negative yOffset) limited by visible bottom; drag up
            // (positive yOffset) limited by overhang past top edge.
            let maxShiftDown = naturalY - minY
            return max(-maxShiftDown, min(overhangLimit, yOffset))
        case .bottom:
            let maxY = visibleFrame.maxY - screenMargin - panelHeight
            let naturalY = visibleFrame.minY + dockEdgeMargin
            let maxShiftUp = maxY - naturalY
            return min(maxShiftUp, max(-overhangLimit, yOffset))
        case .left, .right:
            return 0
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
