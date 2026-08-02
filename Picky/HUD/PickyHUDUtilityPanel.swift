//
//  PickyHUDUtilityPanel.swift
//  Picky
//
//  Tabbed utility panel attached below a Pickle conversation card.
//

import SwiftUI

/// The available utility slots below a Pickle conversation. New slots belong
/// here so their selection, accessibility, and tab treatment stay consistent.
enum PickyHUDUtilityPanelTab: String, CaseIterable, Hashable, Identifiable {
    case terminal
    case changes

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: L10n.t("hud.utilityPanel.tab.terminal")
        case .changes: L10n.t("hud.utilityPanel.tab.changes")
        }
    }
}

/// Pure state and layout policy for the Pickle utility panel.
enum PickyHUDUtilityPanelPolicy {
    static let heightStorageKey = "pickyHUD.utilityPanel.height"
    static let defaultHeight: CGFloat = 240
    static let minimumHeight: CGFloat = 120
    static let maximumHeightFraction: CGFloat = 0.6
    static let resizeGripHeight: CGFloat = 12
    static let minimumConversationCardHeight: CGFloat = 320

    static func selectedTab(
        for sessionID: String,
        selections: [String: PickyHUDUtilityPanelTab]
    ) -> PickyHUDUtilityPanelTab {
        selections[sessionID] ?? .terminal
    }

    static func selectionsAfterSelecting(
        _ tab: PickyHUDUtilityPanelTab,
        sessionID: String,
        selections: [String: PickyHUDUtilityPanelTab]
    ) -> [String: PickyHUDUtilityPanelTab] {
        var next = selections
        next[sessionID] = tab
        return next
    }

    static func openSessionIDsAfterToggling(
        sessionID: String,
        openSessionIDs: Set<String>
    ) -> Set<String> {
        var next = openSessionIDs
        if next.contains(sessionID) {
            next.remove(sessionID)
        } else {
            next.insert(sessionID)
        }
        return next
    }

    static func clampedHeight(_ height: CGFloat, availableCardHeight: CGFloat) -> CGFloat {
        let maximumHeight = max(minimumHeight, availableCardHeight * maximumHeightFraction)
        return min(max(height, minimumHeight), maximumHeight)
    }

    static func conversationCardMaxHeight(
        availableCardHeight: CGFloat,
        utilityPanelHeight: CGFloat
    ) -> CGFloat {
        max(
            minimumConversationCardHeight,
            availableCardHeight - utilityPanelHeight - resizeGripHeight
        )
    }
}

/// A compact tabbed shell whose `changesContent` slot is intentionally owned by
/// the caller. The diff feature can replace the placeholder and provide a badge
/// count without changing terminal lifetime or the panel chrome.
struct PickySessionUtilityPanelView<ChangesContent: View>: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    @Binding var selectedTab: PickyHUDUtilityPanelTab
    let height: CGFloat
    let changesBadgeCount: Int?
    private let changesContent: ChangesContent

    init(
        session: PickySessionListViewModel.SessionCard,
        viewModel: PickySessionListViewModel,
        selectedTab: Binding<PickyHUDUtilityPanelTab>,
        height: CGFloat,
        changesBadgeCount: Int? = nil,
        @ViewBuilder changesContent: () -> ChangesContent
    ) {
        self.session = session
        self.viewModel = viewModel
        self._selectedTab = selectedTab
        self.height = height
        self.changesBadgeCount = changesBadgeCount
        self.changesContent = changesContent()
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
                .overlay(DS.Colors.borderSubtle)
            GeometryReader { proxy in
                ZStack {
                    PickySessionExtendedTerminalView(
                        session: session,
                        viewModel: viewModel,
                        height: proxy.size.height,
                        showsPanelChrome: false
                    )
                    .opacity(selectedTab == .terminal ? 1 : 0)
                    .allowsHitTesting(selectedTab == .terminal)
                    .accessibilityHidden(selectedTab != .terminal)

                    changesContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(selectedTab == .changes ? 1 : 0)
                        .allowsHitTesting(selectedTab == .changes)
                        .accessibilityHidden(selectedTab != .changes)
                }
            }
        }
        .frame(height: height, alignment: .top)
        .background(panelBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.utilityPanel.accessibilityLabel"))
    }

    private var tabBar: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(PickyHUDUtilityPanelTab.allCases) { tab in
                utilityTab(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
    }

    private func utilityTab(_ tab: PickyHUDUtilityPanelTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Text(tab.title)
                    .font(PickyHUDTypography.supportingMedium)
                if tab == .changes, let changesBadgeCount, changesBadgeCount > 0 {
                    Text("\(changesBadgeCount)")
                        .font(PickyHUDTypography.metaSemibold)
                        .foregroundColor(DS.Colors.accentText)
                }
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .hoverAffordance()
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
            .fill(DS.Colors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }
}

struct PickyHUDUtilityPanelChangesPlaceholderView: View {
    var body: some View {
        Text(L10n.t("hud.utilityPanel.changes.placeholder"))
            .font(PickyHUDTypography.supporting)
            .foregroundColor(DS.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(DS.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(L10n.t("hud.utilityPanel.changes.placeholder"))
    }
}

struct PickyHUDUtilityPanelResizeGrip: View {
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle)
                .frame(width: 32, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: PickyHUDUtilityPanelPolicy.resizeGripHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onDragChanged($0.translation.height) }
                .onEnded { _ in onDragEnded() }
        )
        .accessibilityHidden(true)
    }
}
