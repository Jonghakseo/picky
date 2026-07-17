//
//  PickyHUDDockRailView+MinimizedSummary.swift
//  Picky
//
//  Minimized-dock control chrome (minimize chevron, strip surface) and the
//  compact status summary the collapsed rail renders in place of the tiles.
//  Split out of PickyHUDDockRailView so the rail view stays focused on the
//  expanded dock, layout, and drag interaction.
//

import SwiftUI

extension PickyHUDDockRailView {
    // MARK: - Control strip chrome

    /// Minimize/expand chevron. Points "into" the dock body when expanded
    /// (collapse) and back out when minimized (expand), tracking dock side.
    var minimizeChevronButton: some View {
        Button(action: onToggleMinimized) {
            Image(systemName: minimizeChevronSymbol)
                .font(.system(size: max(8, 10 * metrics.scale), weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: metrics.handleAreaHeight, height: metrics.handleAreaHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMinimized ? "Expand dock" : "Minimize dock")
        .accessibilityLabel(isMinimized ? "Expand dock" : "Minimize dock")
    }

    private var minimizeChevronSymbol: String {
        switch dockSide.orientation {
        case .vertical:
            return isMinimized ? "chevron.down" : "chevron.up"
        case .horizontal:
            return isMinimized ? "chevron.right" : "chevron.left"
        }
    }

    var dockStripSurface: some View {
        let shape = Capsule(style: .continuous)
        return PickyHUDMaterialFill(shape: shape, fallback: DS.Colors.surface1)
            .overlay(shape.fill(DS.Colors.surface1.opacity(0.14)))
            .overlay(shape.strokeBorder(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8))
            .compositingGroup()
            .shadow(
                color: Color.black.opacity(PickyHUDExpansion.dockTightShadowOpacity),
                radius: PickyHUDExpansion.dockTightShadowRadius,
                x: 0,
                y: PickyHUDExpansion.dockTightShadowYOffset
            )
    }

    // MARK: - Minimized summary geometry

    private var summaryItems: [PickyHUDDockSummaryItem] {
        PickyHUDDockSummaryPolicy.summary(for: summaryStatuses)
    }

    private var summaryChipCount: Int {
        summaryItems.count
    }

    /// Long-axis extent of one summary chip (height in vertical, width in horizontal).
    private var summaryChipLineHeight: CGFloat { max(15, metrics.statusDotSide + 7) }
    private var summaryChipRowWidth: CGFloat { max(30, metrics.statusDotSide + 22) }

    var minimizedRailLength: CGFloat {
        let count = summaryChipCount
        let spacing = CGFloat(max(0, count - 1)) * metrics.sessionSpacing
        if dockSide.orientation == .horizontal {
            let row = count > 0 ? CGFloat(count) * summaryChipRowWidth + spacing : 0
            return metrics.topPadding + metrics.handleAreaHeight + 2 + row + metrics.topPadding
        }
        let column = count > 0 ? CGFloat(count) * summaryChipLineHeight + spacing : 0
        return metrics.topPadding + metrics.handleAreaHeight + 2 + column + metrics.bottomPadding
    }

    // MARK: - Minimized status summary

    @ViewBuilder
    var minimizedSummary: some View {
        let items = summaryItems
        Group {
            if dockSide.orientation == .horizontal {
                HStack(spacing: metrics.sessionSpacing) { summaryChips(items) }
            } else {
                VStack(spacing: metrics.sessionSpacing) { summaryChips(items) }
            }
        }
        // Tapping the summary is a second, larger affordance to expand the dock
        // (the chevron in the strip is the first). The whole area — including
        // the gaps between chips — is hit-testable.
        .contentShape(Rectangle())
        .onTapGesture { onToggleMinimized() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryAccessibilityLabel(items))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Expand dock")
    }

    @ViewBuilder
    private func summaryChips(_ items: [PickyHUDDockSummaryItem]) -> some View {
        ForEach(items, id: \.status) { item in
            summaryChip(
                dot: summaryDotColor(item.status),
                text: summaryTextColor(item.status),
                count: item.count
            )
        }
    }

    private func summaryChip(dot: Color, text: Color, count: Int) -> some View {
        // Natural-width chip, centered by the enclosing stack. Keeping the chip
        // sized to its content (dot + count) means the block sits symmetrically
        // in the rail instead of leaving empty padding on one side.
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: metrics.statusDotSide, height: metrics.statusDotSide)
            Text("\(count)")
                .pickyFont(size: max(11, 13 * metrics.scale), weight: .semibold)
                .foregroundColor(text)
                .fixedSize()
        }
        .frame(height: dockSide.orientation == .vertical ? summaryChipLineHeight : nil)
    }

    private func summaryDotColor(_ status: PickyHUDDockSummaryStatus) -> Color {
        switch status {
        case .running: DS.Colors.info
        case .waiting: DS.Colors.warning
        case .failed: DS.Colors.destructive
        case .completed: DS.Colors.success
        case .neutral: DS.Colors.textTertiary
        }
    }

    private func summaryTextColor(_ status: PickyHUDDockSummaryStatus) -> Color {
        switch status {
        case .running: DS.Colors.info
        case .waiting: DS.Colors.warningText
        case .failed: DS.Colors.destructiveText
        case .completed: DS.Colors.successText
        case .neutral: DS.Colors.textSecondary
        }
    }

    private func summaryAccessibilityLabel(_ items: [PickyHUDDockSummaryItem]) -> String {
        guard !items.isEmpty else { return "Dock minimized" }
        let parts = items.map { item -> String in
            switch item.status {
            case .running: return "\(item.count) running"
            case .waiting: return "\(item.count) waiting"
            case .failed: return "\(item.count) failed"
            case .completed: return "\(item.count) completed"
            case .neutral: return "\(item.count) idle"
            }
        }
        return "Dock minimized, " + parts.joined(separator: ", ")
    }
}
