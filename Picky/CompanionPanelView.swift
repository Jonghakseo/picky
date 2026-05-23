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
    /// Shared with the HUD dock. The Settings → Pickle screen renders the
    /// archived-Pickle list (with restore/delete affordances) directly off
    /// this view model, so the menu bar panel needs the same instance the HUD
    /// uses instead of a stub.
    @ObservedObject var sessionListViewModel: PickySessionListViewModel
    /// Owns tab + settings-route selection. Hoisted out of `@State` so
    /// `MenuBarPanelManager` (and, by extension, `picky://` deep links from
    /// the conversation) can drive the panel from outside the view.
    @ObservedObject var navigator: PickyPanelNavigator
    @StateObject private var settingsViewModel = PickySettingsViewModel()

    private var selectedTab: CompanionPanelTab { navigator.selectedTab }
    private var settingsRoute: CompanionPanelSettingsRoute { navigator.settingsRoute }
    private var selectedTabBinding: Binding<CompanionPanelTab> {
        Binding(get: { navigator.selectedTab }, set: { navigator.selectedTab = $0 })
    }
    private var settingsRouteBinding: Binding<CompanionPanelSettingsRoute> {
        Binding(get: { navigator.settingsRoute }, set: { navigator.settingsRoute = $0 })
    }
    private var statusRouteBinding: Binding<CompanionPanelStatusRoute> {
        Binding(get: { navigator.statusRoute }, set: { navigator.statusRoute = $0 })
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
                switch selectedTab {
                case .messages:
                    CompanionPanelMessagesView(companionManager: companionManager)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .status:
                    ScrollView(.vertical, showsIndicators: false) {
                        CompanionPanelStatusView(
                            companionManager: companionManager,
                            settingsViewModel: settingsViewModel,
                            route: statusRouteBinding
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                case .settings:
                    // ScrollViewReader so navigating into a leaf (or back to
                    // the index) snaps the scroll position back to the top.
                    // The wrapped ScrollView stays the same instance across
                    // route changes, which is what preserves @State on the
                    // settings drafts — we only reset the offset, never the
                    // view tree.
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 0) {
                                // Sentinel anchor scrolled to whenever the
                                // settings route changes.
                                Color.clear
                                    .frame(height: 0)
                                    .id("settingsScrollAnchor")
                                CompanionPanelSettingsView(
                                    viewModel: settingsViewModel,
                                    companionManager: companionManager,
                                    sessionListViewModel: sessionListViewModel,
                                    route: settingsRouteBinding
                                )
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 12)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                        .onChange(of: navigator.settingsRoute) { _, _ in
                            proxy.scrollTo("settingsScrollAnchor", anchor: .top)
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
    /// matching the iOS-style "tap active tab to go home" gesture. Each tab
    /// with an inner hierarchy resets its own route; Messages has none so it
    /// is a no-op.
    private func popActiveTabToRoot() {
        switch navigator.selectedTab {
        case .status:
            if navigator.statusRoute != .index {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    navigator.statusRoute = .index
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

    /// Snap back to Status whenever the prerequisites become unmet. Without
    /// this, a user who had Messages or Settings open before revoking a
    /// permission (or having Pi go missing) would see a tab bar that's hidden
    /// while their selection points at a tab whose content the prerequisites
    /// surface no longer reaches. The Status sub-route (Feedback) is left
    /// alone — losing a prerequisite mid-form should not silently discard the
    /// user's draft, and the back chevron still works without the tab bar.
    private func handlePrerequisitesChanged(_ met: Bool) {
        if !met {
            navigator.selectedTab = .status
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
                        .pickyFont(size: 12, weight: .semibold)
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
