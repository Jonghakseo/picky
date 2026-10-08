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
    /// Hit area height for the drag handle that lives inside the dock capsule's top
    /// row. The surrounding capsule padding keeps the 14pt row easy to grab without
    /// adding a visually heavy band above the session tiles.
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

    // MARK: Shell chrome

    /// The vertical list rail width is the preset's list width.
    var railWidth: CGFloat { listWidth }
    // Dock chrome stays usable at S without growing to row size at L.
    var utilityButtonSide: CGFloat { 24 }
    var utilitySpacing: CGFloat { 2 }
    var chromeSpacing: CGFloat { 6 }
    var handleInset: CGFloat { 16 }
    var collapseInset: CGFloat { 16 }
    /// Edge-pinned notch keeps a shallower hit depth so it never overlaps the
    /// utilities inside `collapseInset`.
    var collapseHitDepth: CGFloat { 14 }
    /// The move handle widens with the vertical list (30% of the width), from
    /// the original 34pt notch up to 60pt. A horizontal rail keeps 34pt.
    var handleNotchWidth: CGFloat { min(max((listWidth * 0.3).rounded(), 34), 60) }
    var horizontalHandleNotchWidth: CGFloat { 34 }
    var collapseNotchWidth: CGFloat { 28 }
    var notchDepth: CGFloat { 11 }
    var minimizedSide: CGFloat { 32 }
    var minimizedCornerRadius: CGFloat { 10 } // component exception: approved compact restore-button silhouette.
    /// Approved shell radius does not change with the dock preset.
    var outerCornerRadius: CGFloat { 14 }
    /// Shortest notch a horizontal end edge must hold (handle and collapse).
    var horizontalNotchMinLength: CGFloat { 23 }

    /// A thin horizontal rail rounds its ends less, so the straight part of
    /// each end edge can hold its notch. Notches over a rounded corner
    /// would stick out of the shell outline.
    func horizontalShellCornerRadius(thickness: CGFloat) -> CGFloat {
        min(outerCornerRadius, max(0, (thickness - horizontalNotchMinLength) / 2))
    }

    /// Curved shoulder width of a full-length notch.
    static let notchShoulder: CGFloat = 8

    /// Short notches get narrower shoulders so their flat floor stays usable.
    static func notchShoulder(notchLength: CGFloat) -> CGFloat {
        notchLength >= 28 ? notchShoulder : max(3, (notchLength * 0.22).rounded())
    }

    /// The grip stays on the notch's flat floor, clear of both shoulders.
    static func gripLength(preferred: CGFloat, notchLength: CGFloat) -> CGFloat {
        min(preferred, max(6, notchLength - 2 * notchShoulder(notchLength: notchLength) - 2))
    }

    /// Notch length that fits the straight part of a horizontal end edge.
    func horizontalNotchLength(preferred: CGFloat, thickness: CGFloat) -> CGFloat {
        min(preferred, max(0, thickness - 2 * horizontalShellCornerRadius(thickness: thickness)))
    }
    var horizontalPadding: CGFloat { 2 }
    var handleAreaHeight: CGFloat { max(12, scaled(PickyHUDExpansion.dockHandleAreaHeight)) }
    var handleIdleWidth: CGFloat { max((handleNotchWidth * 0.44).rounded(), 15) }
    var horizontalHandleIdleWidth: CGFloat { 15 }
    var handleHeight: CGFloat { 2.5 }
    var plusFontSize: CGFloat { 13 }
    var chromeSeparatorThickness: CGFloat { 0.5 }
    var addSlotCollapsedExpansionReserve: CGFloat { 0 }

    // MARK: List rows (S / M / L)

    /// Vertical list width: S 112, M 168, L 200.
    var listWidth: CGFloat {
        switch preset {
        case .small: 112
        case .medium: 168
        case .large: 200
        }
    }

    /// Large rows add a second status · time line under the title.
    var showsRowDetailLine: Bool { preset == .large }
    func rowHeight(fontScale: CGFloat) -> CGFloat {
        let base: CGFloat = switch preset {
        case .small: 27
        case .medium: 28
        case .large: 38
        }
        return (base * max(1, fontScale)).rounded(.up)
    }

    var rowGlyphSide: CGFloat {
        switch preset {
        case .small, .medium: 15
        case .large: 16
        }
    }

    var rowHorizontalPadding: CGFloat { preset == .small ? 5 : 6 }
    var rowContentSpacing: CGFloat { preset == .small ? 5 : 6 }
    /// A small gap keeps adjacent rows (and their hover/selection fills) apart.
    var rowSpacing: CGFloat { 3 }
    var rowCornerRadius: CGFloat { DS.CornerRadius.control }
    var rowAttentionDotSide: CGFloat { preset == .small ? 5 : 6 }
    var rowUnreadDotSide: CGFloat { 7 }
    var rowActionSide: CGFloat { 18 }

    func groupHeaderHeight(fontScale: CGFloat) -> CGFloat {
        (26 * max(1, fontScale)).rounded(.up)
    }

    /// Group color swatch. A rounded square, so it never reads as the round
    /// unread or attention dots that share the header and rows.
    var groupHeaderSwatchSide: CGFloat { preset == .small ? 8 : 9 }
    var groupHeaderSwatchCornerRadius: CGFloat { 2.5 }
    /// Expanded members sit slightly inside their header.
    var groupMemberIndent: CGFloat { preset == .small ? 4 : 6 }
    /// Extra gap above a collapsed header that follows another entry. Matches
    /// the expanded card's outer gap so the header stays put when toggled.
    var groupHeaderTopGap: CGFloat { groupCardOuterGap }

    // MARK: Expanded group card
    //
    // An expanded group wraps its header and members in one tinted card so
    // members never read as loose Pickles, including in the resting icon lane
    // and between adjacent open groups. Collapsed groups keep the bare header.

    /// Group color behind an expanded group card.
    var groupCardTintOpacity: Double { 0.10 }
    /// Stronger tint while a dragged Pickle targets the card.
    var groupCardDropTintOpacity: Double { 0.18 }
    var groupCardCornerRadius: CGFloat { rowCornerRadius + 2 }
    /// Outside margin on each list-axis side of a card that has a neighbour,
    /// so adjacent open groups never merge into one tinted run.
    var groupCardOuterGap: CGFloat { 2 }
    /// Room under the last member inside a vertical card.
    var groupCardInnerBottom: CGFloat { 2 }
    /// Keeps a horizontal card off the shell's top and bottom edges.
    var groupCardHorizontalCrossInset: CGFloat { 1.5 }

    /// Horizontal chips share the row content at a fixed width.
    var chipWidth: CGFloat {
        switch preset {
        case .small: 88
        case .medium: 118
        case .large: 150
        }
    }

    func chipHeight(fontScale: CGFloat) -> CGFloat {
        let base: CGFloat = switch preset {
        case .small, .medium: 27
        case .large: 38
        }
        return (base * max(1, fontScale)).rounded(.up)
    }

    /// Horizontal rail thickness: chip plus 6pt above and below.
    func horizontalThickness(fontScale: CGFloat) -> CGFloat {
        chipHeight(fontScale: fontScale) + 12
    }

    /// The horizontal A rail keeps square icon cells and reserves a separate
    /// name row. Font scaling grows both, never the hover target's position.
    func horizontalCompactCellSide(fontScale: CGFloat) -> CGFloat {
        max(36, chipHeight(fontScale: fontScale) + 9)
    }

    /// Narrow `+` slot that ends every expanded, non-empty group in the
    /// horizontal rail. Always present, so hovering never shifts the rail.
    func horizontalGroupAddSlotWidth(fontScale: CGFloat) -> CGFloat {
        (22 * max(1, fontScale)).rounded(.up)
    }

    func horizontalPreviewHeight(fontScale: CGFloat) -> CGFloat {
        ceil(30 * max(1, fontScale))
    }

    var horizontalCompactHandleWidth: CGFloat { 20 }
    var horizontalCompactSeparatorWidth: CGFloat { 9 }

    var pickleTitleFontSize: CGFloat {
        PickyHUDTypography.bodyNSFont(fontScale: 1).pointSize - (preset == .small ? 1 : 0)
    }

    var chipSpacing: CGFloat { 3 }
    var horizontalHeaderNameMaxWidth: CGFloat { preset == .small ? 52 : 84 }
    /// Scroll fade length at a clipped list edge.
    var scrollFadeLength: CGFloat { 24 }

    /// Resize tab that sticks out of the free edge.
    var resizeTabDepth: CGFloat { 8 }
    var resizeTabLength: CGFloat { 32 }

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
    /// Default panel width before placement measures a display: the default
    /// card, the gap, and an M dock, plus shadow bleed on both sides.
    static var panelWidth: CGFloat {
        detailWidth + panelGap + railWidth + 2 * PickyHUDExpansion.dockShadowHorizontalPadding
    }
    static let detailWidth: CGFloat = 446
    static let detailHorizontalPadding: CGFloat = 12
    static let contextCompactionPopoverWidth: CGFloat = 252
    static var detailContentWidth: CGFloat { detailContentWidth(for: detailWidth) }
    static func detailContentWidth(for detailWidth: CGFloat) -> CGFloat {
        max(0, detailWidth - (detailHorizontalPadding * 2))
    }
    /// Default vertical rail width (M preset). Real callers pass the live preset width.
    static var railWidth: CGFloat { PickyHUDDockMetrics.medium.railWidth }
    static let panelGap: CGFloat = 10
    static let screenMargin: CGFloat = 8
    /// Visible gap between the dock capsule (and card) and the screen edge it is
    /// pinned to. Tighter than `screenMargin` so the dock visually anchors to the bezel.
    static let dockEdgeMargin: CGFloat = 4
    /// Panel-edge offsets that land the visible chrome `dockEdgeMargin` from the
    /// pinned screen edge. They are negative: the transparent shadow bleed around
    /// the capsule hangs past the visible frame instead of pushing the capsule
    /// inward, and pointer input there already passes through
    /// (`PickyHUDInkPassThroughPolicy` only claims `visibleChromeFrames`).
    static var dockPanelSideInset: CGFloat {
        dockEdgeMargin - PickyHUDExpansion.dockShadowHorizontalPadding
    }
    static var dockPanelTopInset: CGFloat {
        dockEdgeMargin - PickyHUDExpansion.dockShadowTopPadding
    }
    static var dockPanelBottomInset: CGFloat {
        dockEdgeMargin - PickyHUDExpansion.dockShadowBottomPadding
    }
    static let closeDelay = PickyHUDDockHoverDisclosurePolicy.closeGrace
    static let closeDelayNanoseconds = PickyHUDDockHoverDisclosurePolicy.closeGraceNanoseconds
    static let defaultGitSectionExpanded = true

    static var addSlotCollapsedExpansionReserve: CGFloat {
        PickyHUDDockMetrics.medium.addSlotCollapsedExpansionReserve
    }

    static func addSlotFrameHeight(isExpanded: Bool, metrics: PickyHUDDockMetrics = .medium) -> CGFloat {
        metrics.utilityButtonSide
    }

    static func verticalDockRailCrossSize(
        metrics: PickyHUDDockMetrics = .medium
    ) -> CGFloat { metrics.railWidth }

    /// A horizontal rail stops at this length even on a wide screen; the
    /// rest of its rows scroll sideways.
    static let horizontalDockRailMaxLength: CGFloat = 720

    static func horizontalDockRailLengthBudget(screenAvailableLength: CGFloat) -> CGFloat {
        min(screenAvailableLength, horizontalDockRailMaxLength)
    }

    static func horizontalDockRailCrossSize(
        metrics: PickyHUDDockMetrics = .medium,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        metrics.horizontalCompactCellSide(fontScale: fontScale) + metrics.horizontalPreviewHeight(fontScale: fontScale)
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

    /// `horizontalRailLength` is the horizontal rail's on-screen length after
    /// its overflow cap; vertical docks ignore it.
    static func panelWidth(
        cardWidth: CGFloat,
        dockSide: PickyHUDDockSide,
        horizontalRailLength: CGFloat = 0,
        metrics: PickyHUDDockMetrics = .medium,
        dockRailCrossSize: CGFloat? = nil
    ) -> CGFloat {
        switch dockSide.orientation {
        case .vertical:
            return cardWidth
                + panelGap
                + (dockRailCrossSize ?? metrics.railWidth)
                + (PickyHUDExpansion.dockShadowHorizontalPadding * 2)
        case .horizontal:
            return max(cardWidth, horizontalRailLength) + (PickyHUDExpansion.dockShadowHorizontalPadding * 2)
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

    /// Live resize applies the card size on this grid. Every applied size change
    /// re-runs the whole conversation card layout (~40ms with two dozen
    /// messages), and that cost scales with the number of applied updates, not
    /// with drag distance: the same 100pt drag measured 4080ms across 100 1pt
    /// updates versus 505ms across 12 8pt updates. The grid matches
    /// `PickyConversationBubbleLayout.widthQuantum` so bubble caps and card
    /// width step together instead of thrashing the measurement cache.
    static let resizeStep: CGFloat = 8

    static func resizedCardSize(
        from startSize: PickyHUDCardSize,
        delta: CGPoint,
        dockSide: PickyHUDDockSide,
        maxWidth: CGFloat = PickyHUDCardSize.widthRange.upperBound,
        maxHeight: CGFloat = PickyHUDCardSize.heightRange.upperBound,
        step: CGFloat = resizeStep
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
            width: snapped(rawWidth, step: step),
            height: snapped(rawHeight, step: step),
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
    }

    private static func snapped(_ value: CGFloat, step: CGFloat) -> CGFloat {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }


    // Compatibility forwarding shim: the HUD view still imports dock layout,
    // interaction, and geometry decisions through this single policy namespace.
    // Keep these pass-throughs until call sites are split in a focused HUD
    // cleanup so behavior changes do not get mixed with namespace churn.
    static func activeSessionID(visibleIDs: [String], held: PickyHUDDockHold?) -> String? {
        PickyHUDDockInteractionPolicy.activeSessionID(visibleIDs: visibleIDs, held: held)
    }

    static func heldSessionAfterCloseTimeout(current: PickyHUDDockHold?, isHUDHovered: Bool) -> PickyHUDDockHold? {
        PickyHUDDockInteractionPolicy.heldSessionAfterCloseTimeout(current: current, isHUDHovered: isHUDHovered)
    }

    static func heldSessionAfterClick(current: PickyHUDDockHold?, clicked: String) -> PickyHUDDockHold? {
        PickyHUDDockInteractionPolicy.heldSessionAfterClick(current: current, clicked: clicked)
    }

    static func manualAutoOpenResolution(pendingSessionID: String?, visibleIDs: [String]) -> PickyHUDDockHold? {
        PickyHUDDockInteractionPolicy.manualAutoOpenResolution(pendingSessionID: pendingSessionID, visibleIDs: visibleIDs)
    }

    static func requestedOpenResolution(pendingSessionID: String?, visibleIDs: [String]) -> PickyHUDDockHold? {
        PickyHUDDockInteractionPolicy.requestedOpenResolution(pendingSessionID: pendingSessionID, visibleIDs: visibleIDs)
    }

    static func numberShortcutForSessionIndex(_ index: Int) -> Int? {
        PickyHUDDockInteractionPolicy.numberShortcutForSessionIndex(index)
    }

    static func sessionIDForNumberShortcut(visibleIDs: [String], number: Int) -> String? {
        PickyHUDDockInteractionPolicy.sessionIDForNumberShortcut(visibleIDs: visibleIDs, number: number)
    }

    static func heldSessionAfterNumberShortcut(current: PickyHUDDockHold?, visibleIDs: [String], number: Int) -> PickyHUDDockHold? {
        PickyHUDDockInteractionPolicy.heldSessionAfterNumberShortcut(
            current: current,
            visibleIDs: visibleIDs,
            number: number
        )
    }

    static func heldSessionAfterCycleShortcut(current: PickyHUDDockHold?, visibleIDs: [String], direction: Int) -> PickyHUDDockHold? {
        PickyHUDDockInteractionPolicy.heldSessionAfterCycleShortcut(
            current: current,
            visibleIDs: visibleIDs,
            direction: direction
        )
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
            raw = visibleFrame.maxX - panelWidth - dockPanelSideInset + xOffset
        case .left:
            raw = visibleFrame.minX + dockPanelSideInset + xOffset
        case .top, .bottom:
            // Vertical-only helper; horizontal callers use `horizontalPanelX`.
            // Fall back to the `.right` placement so accidental misuse stays on
            // screen instead of producing NaN.
            raw = visibleFrame.maxX - panelWidth - dockPanelSideInset + xOffset
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
        dockRailWidth: CGFloat = railWidth,
        keepVisible: CGFloat = railWidth / 2
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
            dockRailWidth: dockRailWidth,
            keepVisible: keepVisible
        )
    }

    static func horizontalPanelX(
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        xOffset: CGFloat = 0,
        dockRailLength: CGFloat = 0,
        keepVisible: CGFloat = railWidth
    ) -> CGFloat {
        let safeOffset = clampedHorizontalXOffset(
            xOffset,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockRailLength: dockRailLength,
            keepVisible: keepVisible
        )
        let raw = visibleFrame.midX - (panelWidth / 2) + safeOffset
        return raw.rounded(.toNearestOrEven)
    }

    /// Clamp the horizontal mode's X-axis nudge. With `dockRailLength`, the
    /// leading handle slot must remain visible while the rest of the rail may
    /// slide off the trailing edge. Without a rail length, fall back to the
    /// historical center-within-screen-margin behavior.
    static func clampedHorizontalXOffset(
        _ xOffset: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        dockRailLength: CGFloat = 0,
        keepVisible: CGFloat = railWidth
    ) -> CGFloat {
        let dockHalfLength = max(dockRailLength / 2, 0)
        let minDockCenter: CGFloat
        let maxDockCenter: CGFloat
        if dockRailLength > 0 {
            // Horizontal rail's drag handle is the leading slot. Let the rest of
            // the rail slide off the trailing edge, but keep that full handle
            // slot on-screen so the dock always remains grabbable.
            let keep = min(max(keepVisible, 0), dockRailLength)
            minDockCenter = visibleFrame.minX + dockHalfLength
            maxDockCenter = visibleFrame.maxX - keep + dockHalfLength
        } else {
            minDockCenter = visibleFrame.minX + screenMargin
            maxDockCenter = visibleFrame.maxX - screenMargin
        }
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
            return (visibleFrame.maxY - targetHeight - dockPanelTopInset + yOffset).rounded(.toNearestOrEven)
        case .bottom:
            // +yOffset = drag up (dock slides toward center).
            // -yOffset = drag down past the bottom edge for overhang.
            return (visibleFrame.minY + dockPanelBottomInset + yOffset).rounded(.toNearestOrEven)
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
        dockRailHeight: CGFloat,
        keepVisible: CGFloat = railWidth / 2
    ) -> CGFloat {
        let overhangLimit = dockOverhangLimit(forRailWidth: dockRailHeight, keepVisible: keepVisible)
        switch dockSide {
        case .top:
            let minY = visibleFrame.minY + screenMargin
            let naturalY = visibleFrame.maxY - panelHeight - dockPanelTopInset
            // Drag down (negative yOffset) limited by visible bottom; drag up
            // (positive yOffset) limited by overhang past top edge.
            let maxShiftDown = naturalY - minY
            return max(-maxShiftDown, min(overhangLimit, yOffset))
        case .bottom:
            let maxY = visibleFrame.maxY - screenMargin - panelHeight
            let naturalY = visibleFrame.minY + dockPanelBottomInset
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
    /// when only half the rail must remain visible. Retained for callers/tests that
    /// intentionally choose a smaller `keepVisible` than a full handle slot.
    static var dockOverhangLimit: CGFloat { (railWidth / 2).rounded(.down) }

    static func dockOverhangLimit(forRailWidth dockRailWidth: CGFloat, keepVisible: CGFloat = railWidth / 2) -> CGFloat {
        max(0, dockRailWidth - keepVisible).rounded(.down)
    }

    /// Clamp a vertical-mode X offset so the dock can move inward freely while the
    /// requested visible width of the handle slot remains on-screen.
    static func clampedXOffset(
        _ xOffset: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        dockSide: PickyHUDDockSide,
        dockRailWidth: CGFloat = railWidth,
        keepVisible: CGFloat = railWidth / 2
    ) -> CGFloat {
        let overhangLimit = dockOverhangLimit(forRailWidth: dockRailWidth, keepVisible: keepVisible)
        switch dockSide {
        case .right, .top, .bottom:
            let minX = visibleFrame.minX + screenMargin
            let naturalX = visibleFrame.maxX - panelWidth - dockPanelSideInset
            let maxShiftLeft = naturalX - minX
            return max(-maxShiftLeft, min(overhangLimit, xOffset))
        case .left:
            let maxX = visibleFrame.maxX - screenMargin - panelWidth
            let naturalX = visibleFrame.minX + dockPanelSideInset
            let maxShiftRight = maxX - naturalX
            return min(maxShiftRight, max(-overhangLimit, xOffset))
        }
    }

    // MARK: - Dock-top anchored placement

    /// Lowest NSPanel origin Y for a vertical dock. The visible dock and card
    /// bottoms stop `dockEdgeMargin` above the visible frame; only the transparent
    /// bottom shadow bleed may hang below it.
    static func dockAnchoredPanelBottomFloor(visibleFrame: CGRect) -> CGFloat {
        visibleFrame.minY + dockPanelBottomInset
    }

    /// Largest anchor percent that still keeps `keepVisible` (one dock handle slot)
    /// of the rail above the screen's bottom edge. Screen-aware so taller displays
    /// allow dragging the dock farther down than the old flat 70% cap.
    static func maxDockTopAnchorPercent(visibleHeight: CGFloat, keepVisible: CGFloat = railWidth) -> Double {
        guard visibleHeight > 0 else { return PickySettings.dockTopAnchorPercentRange.upperBound }
        let raw = 100.0 * (1.0 - Double(max(keepVisible, 0)) / Double(visibleHeight))
        let lower = PickySettings.dockTopAnchorPercentRange.lowerBound
        let upper = PickySettings.dockTopAnchorPercentRange.upperBound
        return min(max(raw, lower), upper)
    }

    /// Screen Y of the dock's top edge for a given anchor percent (from the top of
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
        return max(originY, dockAnchoredPanelBottomFloor(visibleFrame: visibleFrame))
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
        let minimumY = dockAnchoredPanelBottomFloor(visibleFrame: visibleFrame).rounded(.up)
        return max(panelTopY - targetHeight, minimumY)
    }

    /// Largest panel height that still lets `dockTopAnchoredPanelY` keep the dock at
    /// `dockTopScreenY` without falling through `dockAnchoredPanelBottomFloor`.
    /// The conversation list inside the card has its own ScrollView so anything
    /// requesting more height scrolls in place rather than overflowing the screen.
    static func dockTopAnchoredMaxPanelHeight(
        visibleFrame: CGRect,
        topPaddingFromContentTop: CGFloat,
        anchorPercent: Double
    ) -> CGFloat {
        let dockTopY = dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: anchorPercent)
        let bottomFloor = dockAnchoredPanelBottomFloor(visibleFrame: visibleFrame)
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
        let bottomFloor = dockAnchoredPanelBottomFloor(visibleFrame: visibleFrame).rounded(.up)
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
        case .completed: return hasReportArtifact ? L10n.t("hud.event.reportReady") : L10n.t("hud.event.result")
        case .failed: return L10n.t("hud.conversation.status.failed")
        case .cancelled: return L10n.t("hud.state.cancelled")
        case .blocked: return L10n.t("hud.state.blocked")
        case .waiting_for_input: return L10n.t("hud.event.awaitingInput")
        case .running, .queued: return L10n.t("hud.event.update")
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

/// Rate limit for applying live card-resize sizes. Grid snapping alone scales
/// with drag distance, so a fast flick still applies dozens of sizes per second
/// at ~40ms of card layout each. This caps the applied rate regardless of
/// pointer speed, and the trailing schedule keeps the final pointer position.
enum PickyHUDCardResizeApplyThrottle {
    static let minimumInterval: TimeInterval = 1.0 / 30

    enum Decision: Equatable {
        case applyNow
        case scheduleAfter(TimeInterval)
    }

    static func decide(
        lastAppliedAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = minimumInterval
    ) -> Decision {
        guard let lastAppliedAt else { return .applyNow }
        let elapsed = now.timeIntervalSince(lastAppliedAt)
        guard elapsed < minimumInterval else { return .applyNow }
        return .scheduleAfter(minimumInterval - elapsed)
    }
}
