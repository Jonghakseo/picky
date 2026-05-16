//
//  CompanionPanelView.swift
//  Picky
//
//  The SwiftUI content hosted inside the menu bar panel.
//

import SwiftUI

enum CompanionPanelMetrics {
    static let contentWidth: CGFloat = 360
    static let contentHeight: CGFloat = 500
    static let cornerRadius: CGFloat = 18

    static var panelWidth: CGFloat { contentWidth }
    static var panelHeight: CGFloat { contentHeight }
}

/// Internal so `PickyPanelNavigator` can drive tab selection from outside
/// the panel view. The raw values stay English on purpose — logs and any
/// persisted debug state read them, and we don't want translation drift
/// silently breaking those callsites.
enum CompanionPanelTab: String, CaseIterable, Identifiable {
    case status = "Status"
    case messages = "Messages"
    case settings = "Settings"

    var id: String { rawValue }

    /// Catalog key for the tab's user-facing label. Distinct from `rawValue`
    /// (which stays English so debug logs and persistence aren't tied to
    /// translation drift). SwiftUI `Text(_:)` accepts a `LocalizedStringKey`
    /// directly so passing this keeps env-locale propagation working.
    var labelKey: LocalizedStringKey {
        switch self {
        case .status: "tab.status"
        case .messages: "tab.messages"
        case .settings: "tab.settings"
        }
    }

    var icon: String {
        switch self {
        case .status: "sparkles"
        case .messages: "bubble.left.and.bubble.right"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Owns tab + settings-route selection. Hoisted out of `@State` so
    /// `MenuBarPanelManager` (and, by extension, `picky://` deep links from
    /// the conversation) can drive the panel from outside the view.
    @ObservedObject var navigator: PickyPanelNavigator
    @StateObject private var settingsViewModel = PickySettingsViewModel()
    /// Feedback is reached only via the Status tab deep link, so it renders
    /// as a top-level overlay rather than a Settings sub-page. Keeping it
    /// outside the tab switch means the tab bar can keep showing Status as
    /// active while the user fills out the form, matching the back chevron.
    @State private var isShowingFeedback: Bool = false

    private var selectedTab: CompanionPanelTab { navigator.selectedTab }
    private var settingsRoute: CompanionPanelSettingsRoute { navigator.settingsRoute }
    private var selectedTabBinding: Binding<CompanionPanelTab> {
        Binding(get: { navigator.selectedTab }, set: { navigator.selectedTab = $0 })
    }
    private var settingsRouteBinding: Binding<CompanionPanelSettingsRoute> {
        Binding(get: { navigator.settingsRoute }, set: { navigator.settingsRoute = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompanionPanelHeaderView(companionManager: companionManager)

            // Hide the tab bar during setup so the prerequisites surface gets
            // the user's full attention. The Status tab content keeps rendering
            // (with the prerequisites view inside) and the feedback overlay
            // stays reachable through the Status entry row so the user never
            // has to discover the tab bar to escape. Messages/Settings reappear
            // as soon as every prerequisite is satisfied.
            if companionManager.allPrerequisitesMet {
                CompanionPanelTabBar(
                    selectedTab: selectedTabBinding,
                    onTapActiveTab: popActiveTabToRoot
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 0)
            }

            Group {
                if isShowingFeedback {
                    feedbackOverlay
                } else {
                    switch selectedTab {
                    case .messages:
                        CompanionPanelMessagesView(companionManager: companionManager)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    case .status, .settings:
                        ScrollView(.vertical, showsIndicators: selectedTab == .settings) {
                            Group {
                                switch selectedTab {
                                case .status:
                                    CompanionPanelStatusView(
                                        companionManager: companionManager,
                                        settingsViewModel: settingsViewModel,
                                        onShowFeedback: showFeedback
                                    )
                                case .messages:
                                    EmptyView()
                                case .settings:
                                    CompanionPanelSettingsView(
                                        viewModel: settingsViewModel,
                                        companionManager: companionManager,
                                        route: settingsRouteBinding
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.5))
                .padding(.horizontal, 16)

            CompanionPanelFooterView()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: CompanionPanelMetrics.contentWidth, height: CompanionPanelMetrics.contentHeight)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: CompanionPanelMetrics.cornerRadius, style: .continuous))
        .frame(width: CompanionPanelMetrics.panelWidth, height: CompanionPanelMetrics.panelHeight)
        .background(Color.clear)
        .onAppear { handlePrerequisitesChanged(companionManager.allPrerequisitesMet) }
        .onChange(of: companionManager.allPrerequisitesMet) { _, newValue in
            handlePrerequisitesChanged(newValue)
        }
    }

    /// Re-tap of the already-active tab pops that tab back to its root view,
    /// matching the iOS-style "tap active tab to go home" gesture. Status
    /// pops the feedback overlay; Settings pops any sub-route back to the
    /// index; Messages has no inner hierarchy so it's a no-op.
    private func popActiveTabToRoot() {
        switch navigator.selectedTab {
        case .status:
            if isShowingFeedback {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    isShowingFeedback = false
                }
            }
        case .settings:
            if navigator.settingsRoute != .index {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    navigator.settingsRoute = .index
                }
            }
        case .messages:
            break
        }
    }

    private func showFeedback() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            navigator.selectedTab = .status
            isShowingFeedback = true
        }
    }

    /// Mirror of showFeedback: feedback is a Status-tab drill-down, so its
    /// back chevron just collapses the overlay and reveals the Status content
    /// again. Tab selection never moved, so nothing else needs resetting.
    private func exitFeedbackToStatus() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            isShowingFeedback = false
        }
    }

    /// Snap back to Status whenever the prerequisites become unmet. Without
    /// this, a user who had Messages or Settings open before revoking a
    /// permission (or having Pi go missing) would see a tab bar that's hidden
    /// while their selection points at a tab whose content the prerequisites
    /// surface no longer reaches. The feedback overlay is allowed to keep
    /// rendering — losing a prerequisite mid-form should not silently discard
    /// the user's draft, and the back chevron still works without the tab bar.
    private func handlePrerequisitesChanged(_ met: Bool) {
        if !met {
            navigator.selectedTab = .status
        }
    }

    /// Feedback page rendered above the tab content. Mirrors the layout of a
    /// Settings sub-page (back chevron + section header + form) but lives at
    /// the panel level so the tab bar can keep highlighting Status — the tab
    /// the user actually came from and will return to.
    private var feedbackOverlay: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: exitFeedbackToStatus) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("tab.status")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 9) {
                    Text("settings.section.feedback.title")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Text("settings.section.feedback.subtitle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    CompanionPanelFeedbackView(viewModel: settingsViewModel)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: CompanionPanelMetrics.cornerRadius, style: .continuous)
            .fill(DS.Colors.background)
            .overlay(
                RoundedRectangle(cornerRadius: CompanionPanelMetrics.cornerRadius, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
            )
    }
}

/// Minimal tab bar: text-only buttons sitting on a hairline divider. The active tab is
/// signalled by a 1.5pt indicator under its label rather than a pill background, so the
/// whole row reads as a row of text rather than a row of chips. The icons that the older
/// design used to lean on are dropped; the three labels (Status / Messages / Settings)
/// are short enough to identify themselves.
private struct CompanionPanelTabBar: View {
    @Binding var selectedTab: CompanionPanelTab
    /// Called when the user taps the tab that is already active. The parent
    /// uses this to bump a nonce that scrolls the visible tab back to its top,
    /// matching the iOS-style "tap active tab to return to top" gesture.
    var onTapActiveTab: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CompanionPanelTab.allCases) { tab in
                Button {
                    if selectedTab == tab {
                        onTapActiveTab()
                    } else {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                            selectedTab = tab
                        }
                    }
                } label: {
                    Text(tab.labelKey)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selectedTab == tab ? DS.Colors.textPrimary : Color.clear)
                                .frame(height: 1.5)
                                .offset(y: 0.5)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.5))
                .frame(height: 0.5)
        }
    }
}
