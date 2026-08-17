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
    case progress
    case artifacts

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: L10n.t("hud.utilityPanel.tab.terminal")
        case .progress: L10n.t("hud.utilityPanel.tab.progress")
        case .artifacts: L10n.t("hud.utilityPanel.tab.artifacts")
        }
    }
}

enum PickyHUDUtilityPanelTabBadge: Equatable {
    case count(Int)
    case running
}

/// Pure state and layout policy for the Pickle utility panel.
enum PickyHUDUtilityPanelPolicy {
    static let heightStorageKey = "pickyHUD.utilityPanel.height"
    static let defaultHeight: CGFloat = 240
    static let minimumHeight: CGFloat = 120
    static let maximumHeightFraction: CGFloat = 0.6
    static let resizeGripHeight: CGFloat = 12
    static let minimumConversationCardHeight: CGFloat = 320

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

/// A compact three-tab shell. The terminal stays mounted behind the other tabs
/// so its process and scroll state survive utility-panel navigation.
struct PickySessionUtilityPanelView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    @Binding var selectedTab: PickyHUDUtilityPanelTab
    let height: CGFloat
    let artifactsBadge: PickyHUDUtilityPanelTabBadge?
    let activityBadge: PickyHUDUtilityPanelTabBadge?

    init(
        session: PickySessionListViewModel.SessionCard,
        viewModel: PickySessionListViewModel,
        selectedTab: Binding<PickyHUDUtilityPanelTab>,
        height: CGFloat,
        artifactsBadge: PickyHUDUtilityPanelTabBadge? = nil,
        activityBadge: PickyHUDUtilityPanelTabBadge? = nil
    ) {
        self.session = session
        self.viewModel = viewModel
        self._selectedTab = selectedTab
        self.height = height
        self.artifactsBadge = artifactsBadge
        self.activityBadge = activityBadge
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
                        showsPanelChrome: false,
                        isFocusEligible: selectedTab == .terminal
                    )
                    .opacity(selectedTab == .terminal ? 1 : 0)
                    .allowsHitTesting(selectedTab == .terminal)
                    .accessibilityHidden(selectedTab != .terminal)

                    PickySessionProgressView(session: session)
                        .opacity(selectedTab == .progress ? 1 : 0)
                        .allowsHitTesting(selectedTab == .progress)
                        .accessibilityHidden(selectedTab != .progress)

                    PickySessionArtifactsView(artifacts: session.artifacts)
                        .opacity(selectedTab == .artifacts ? 1 : 0)
                        .allowsHitTesting(selectedTab == .artifacts)
                        .accessibilityHidden(selectedTab != .artifacts)
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
                if let badge = badge(for: tab) {
                    badgeView(badge)
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

    private func badge(for tab: PickyHUDUtilityPanelTab) -> PickyHUDUtilityPanelTabBadge? {
        switch tab {
        case .terminal: nil
        case .progress: activityBadge
        case .artifacts: artifactsBadge
        }
    }

    @ViewBuilder
    private func badgeView(_ badge: PickyHUDUtilityPanelTabBadge) -> some View {
        switch badge {
        case let .count(count):
            if count > 0 {
                Text("\(count)")
                    .font(PickyHUDTypography.metaSemibold)
                    .foregroundColor(DS.Colors.accentText)
            }
        case .running:
            PickyHUDUtilityPanelRunningBadge()
        }
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

private struct PickyHUDUtilityPanelRunningBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: "circle.fill")
            .font(PickyHUDTypography.minimum)
            .foregroundColor(DS.Colors.info)
            .opacity(isPulsing ? 0.48 : 1)
            .accessibilityLabel(L10n.t("hud.progress.badge.running"))
            .onAppear { updatePulse() }
            .onChange(of: reduceMotion) { _, _ in updatePulse() }
    }

    private func updatePulse() {
        guard !reduceMotion else {
            isPulsing = false
            return
        }
        withAnimation(.easeInOut(duration: DS.Animation.fast).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
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
