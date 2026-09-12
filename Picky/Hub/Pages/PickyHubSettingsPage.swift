//
//  PickyHubSettingsPage.swift
//  Picky
//

import AppKit
import SwiftUI

struct PickyHubSettingsPage: View {
    let dependencies: PickyHubDependencies
    @ObservedObject private var settingsViewModel: PickySettingsViewModel
    @ObservedObject private var permissions: PickyPermissionMonitor
    @EnvironmentObject private var navigator: PickyHubNavigator
    @EnvironmentObject private var modalHost: PickyHubModalHost
    @State private var statisticsResetState: PickyHubStatisticsResetState = .idle
    @State private var onboardingReplayState: PickyHubOnboardingReplayState = .idle
    @State private var onboardingReplayTransaction: PickyHubOnboardingReplaySaveTransaction?
    @State private var settingsNavigationState = PickyHubSettingsNavigationState()
    @State private var pendingDisclosureScrollTarget: String?
    @State private var activeSettingsGroup: PickyHubSettingsGroup = .general
    @State private var settingsGroupOffsets: [String: CGFloat] = [:]
    @State private var pinnedNavigationHeight: CGFloat = 0
    @State private var pendingGroupScrollTarget: String?
    @State private var scrollCoordinator = PickyHubSettingsScrollCoordinator()
    @FocusState private var focusedSettingsControl: String?

    private static let scrollCoordinateSpace = "PickyHubSettingsScroll"

    init(dependencies: PickyHubDependencies) {
        self.dependencies = dependencies
        _settingsViewModel = ObservedObject(wrappedValue: dependencies.settingsViewModel)
        _permissions = ObservedObject(wrappedValue: dependencies.permissions)
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        // Keep the page's initial top inset with the scrolling title,
                        // not the lazy container. A container inset becomes a gap above
                        // the pinned header in the Hub's full-size titlebar window.
                        PickyHubPageHeader(title: PickyHubPage.settings.titleKey, subtitle: "hub.page.settings.subtitle")
                            .padding(.top, PickyHubTheme.Layout.contentTopPadding)
                        Section {
                            // Keep all targets instantiated so settings deep links can scroll
                            // to a group or expanded leaf before it enters the viewport.
                            VStack(alignment: .leading, spacing: 0) {
                                if restartRequired {
                                    PickyHubInlineStatus(
                                        tone: .warning,
                                        message: L10n.t("hub.settings.restart.message"),
                                        actionTitle: "hub.settings.restart.action",
                                        action: { PickyRelauncher.relaunchAndTerminate() }
                                    )
                                    .padding(.bottom, PickyHubTheme.Spacing.field)
                                }
                                ForEach(PickyHubSettingsGroup.allCases) { group in
                                    PickyHubSettingsGroupSection(group: group) {
                                        groupContent(group, scrollProxy: proxy)
                                    }
                                    .id(group.id)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: PickyHubSettingsGroupOffsetPreference.self,
                                                value: [
                                                    group.id: geometry.frame(
                                                        in: .named(Self.scrollCoordinateSpace)
                                                    ).minY,
                                                ]
                                            )
                                        }
                                    }
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 0) {
                                groupLinks(proxy)
                                    .padding(.vertical, DS.Spacing.space3)
                                Divider().overlay(PickyHubTheme.Colors.borderSoft)
                                Color.clear.frame(height: PickyHubTheme.Spacing.field)
                            }
                            .background {
                                PickyHubTheme.Colors.canvas
                                    .padding(
                                        .horizontal,
                                        -PickyHubTheme.Layout.contentHorizontalPadding
                                    )
                            }
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: PickyHubSettingsNavigationHeightPreference.self,
                                        value: geometry.size.height
                                    )
                                }
                            }
                            .zIndex(1)
                        }
                    }
                    .background {
                        PickyHubSettingsScrollViewResolver { scrollView in
                            scrollCoordinator.attach(to: scrollView)
                        }
                    }
                    .frame(maxWidth: PickyHubTheme.Layout.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, PickyHubTheme.Layout.contentHorizontalPadding)
                    .padding(.bottom, PickyHubTheme.Layout.contentBottomPadding)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: Self.scrollCoordinateSpace)
                .environment(\.pickyUsesSubtleMenuChrome, true)
                .onAppear { consumePendingSettingsNavigation(with: proxy) }
                .onChange(of: navigator.pendingSettingsNavigation) { _, _ in
                    consumePendingSettingsNavigation(with: proxy)
                }
                .onPreferenceChange(PickyHubSettingsGroupOffsetPreference.self) { offsets in
                    settingsGroupOffsets = offsets
                    updateActiveSettingsGroup()
                    applyPendingGroupScrollAdjustment(using: offsets)
                }
                .onPreferenceChange(PickyHubSettingsNavigationHeightPreference.self) { height in
                    pinnedNavigationHeight = height
                    updateActiveSettingsGroup()
                    applyPendingGroupScrollAdjustment(using: settingsGroupOffsets)
                }
            }
            // The full-size transparent titlebar lets scroll content underlap its
            // safe area. This sibling mask stays outside the pinned Section's
            // clipping boundary and keeps that strip visually quiet.
            .overlay(alignment: .top) {
                PickyHubTheme.Colors.canvas
                    .frame(height: viewport.safeAreaInsets.top)
                    .offset(y: -viewport.safeAreaInsets.top)
                    .allowsHitTesting(false)
            }
        }
    }

    private var restartRequired: Bool {
        PickyRestartSettingsSnapshotStore.requirement(for: settingsViewModel.settings).isRequired
    }

    private func groupLinks(_ proxy: ScrollViewProxy) -> some View {
        PickyHubSettingsBadgeLayout(
            spacing: PickyHubTheme.Spacing.related,
            maximumItemsPerRow: PickyHubSettingsLayout.maximumBadgesPerRow
        ) {
            ForEach(PickyHubSettingsGroup.allCases) { group in
                PickyHubSettingsGroupBadge(
                    group: group,
                    isSelected: activeSettingsGroup == group
                ) {
                    scrollTo(group.id, with: proxy)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("hub.settings.groupLinks"))
    }

    @ViewBuilder
    private func groupContent(_ group: PickyHubSettingsGroup, scrollProxy: ScrollViewProxy) -> some View {
        switch group {
        case .general:
            embedded(.general)
            PickyHubGeneralControls(
                settingsViewModel: settingsViewModel,
                appearanceStore: dependencies.appearanceStore,
                fontScaleStore: dependencies.fontScaleStore,
                updaterController: dependencies.updaterController,
                focusedControl: $focusedSettingsControl,
                replayOnboarding: presentOnboardingConfirmation
            )
        case .agents:
            embedded(.oauth)
            embedded(.mainAgent)
            PickyHubSettingsDisclosure(
                title: "hub.settings.agents.advanced",
                isExpanded: Binding(
                    get: { settingsNavigationState.isExpanded(.agentTools) },
                    set: { isExpanded in
                        settingsNavigationState.setExpanded(.agentTools, to: isExpanded)
                    }
                ),
                onExpandedContentAppear: {
                    scrollToPendingDisclosureTarget(
                        PickyHubSettingsLeaf.builtinTools.scrollTargetID,
                        with: scrollProxy
                    )
                },
                content: {
                    embedded(.builtinTools)
                        .id(PickyHubSettingsLeaf.builtinTools.scrollTargetID)
                }
            )
        case .voice:
            embedded(.voice)
            embedded(.shortcuts)
        case .overlay:
            embedded(.overlayAndNotifications, presentation: .embeddedOverlayControls)
                .id(PickyHubSettingsLeaf.cursorBubbles.scrollTargetID)
        case .workspace:
            embedded(.pickle)
            PickyHubPickleFolderControls(settingsViewModel: settingsViewModel)
        case .privacy:
            PickyHubClassificationSettingsView(statisticsStore: dependencies.statisticsStore)
            PickyHubNotificationControls(settingsViewModel: settingsViewModel)
                .id(PickyHubSettingsLeaf.notifications.scrollTargetID)
            PickyHubPermissionRows(permissions: permissions)
            PickyHubSettingsNotice(text: "hub.settings.privacy.notice")
        case .advanced:
            PickyHubAdvancedControls(
                settingsViewModel: settingsViewModel,
                focusedControl: $focusedSettingsControl,
                resetStatistics: presentStatisticsResetConfirmation,
                resetState: statisticsResetState
            )
        }
    }

    @ViewBuilder
    private func embedded(
        _ route: CompanionPanelSettingsRoute,
        presentation: CompanionPanelSettingsPresentation = .embedded
    ) -> some View {
        let settings = CompanionPanelSettingsView(
            viewModel: settingsViewModel,
            companionManager: dependencies.companionManager,
            mainConversation: dependencies.companionManager.mainConversation,
            archiveMembership: dependencies.sessionListViewModel.sessionRegistry,
            archiveCommands: dependencies.sessionListViewModel,
            route: .constant(route),
            presentation: presentation
        )

        if route == .mainAgent, presentation == .embedded {
            settings
        } else {
            settings
                .padding(PickyHubTheme.Spacing.cardInset)
                .pickyHubCard(radius: PickyHubTheme.Radius.card)
        }
    }

    private func consumePendingSettingsNavigation(with proxy: ScrollViewProxy) {
        guard let request = navigator.consumePendingSettingsNavigation() else { return }
        pendingDisclosureScrollTarget = nil
        let disclosureWasExpanded = request.leaf
            .flatMap(\.disclosure)
            .map(settingsNavigationState.isExpanded) ?? true
        let target = settingsNavigationState.apply(request)
        guard disclosureWasExpanded else {
            pendingDisclosureScrollTarget = target
            return
        }
        scrollTo(target, with: proxy)
    }

    private func scrollToPendingDisclosureTarget(_ target: String, with proxy: ScrollViewProxy) {
        guard pendingDisclosureScrollTarget == target else { return }
        pendingDisclosureScrollTarget = nil
        scrollTo(target, with: proxy)
    }

    private func scrollTo(_ target: String, with proxy: ScrollViewProxy) {
        pendingGroupScrollTarget = PickyHubSettingsGroup.allCases.contains { $0.id == target }
            ? target
            : nil
        proxy.scrollTo(target, anchor: .top)
    }

    private func applyPendingGroupScrollAdjustment(using offsets: [String: CGFloat]) {
        guard let target = pendingGroupScrollTarget,
              let targetOffset = offsets[target],
              pinnedNavigationHeight > 0
        else { return }

        let clearance = pinnedNavigationHeight + PickyHubTheme.Spacing.field
        if targetOffset >= clearance - 0.5 {
            pendingGroupScrollTarget = nil
            return
        }
        guard scrollCoordinator.align(targetOffset: targetOffset, below: clearance) else { return }
        pendingGroupScrollTarget = nil
    }

    private func updateActiveSettingsGroup() {
        guard !settingsGroupOffsets.isEmpty else { return }
        let activationLine = pinnedNavigationHeight + PickyHubTheme.Spacing.field
        let orderedOffsets = PickyHubSettingsGroup.allCases.compactMap { group in
            settingsGroupOffsets[group.id].map { (group: group, offset: $0) }
        }
        let nextGroup = orderedOffsets
            .filter { $0.offset <= activationLine }
            .max { $0.offset < $1.offset }?.group
            ?? orderedOffsets.min { $0.offset < $1.offset }?.group
        if let nextGroup, nextGroup != activeSettingsGroup {
            activeSettingsGroup = nextGroup
        }
    }

    private func presentOnboardingConfirmation() {
        onboardingReplayState = .idle
        onboardingReplayTransaction = nil
        modalHost.present(
            width: 430,
            accessibilityLabel: L10n.t("hub.settings.onboarding.dialog.title"),
            canDismiss: { !onboardingReplayState.isSaving },
            onWillDismiss: cancelOnboardingReplayIfNeeded,
            onDismiss: restoreOnboardingTrigger
        ) {
            PickyHubOnboardingReplayConfirmation(
                state: $onboardingReplayState,
                onCancel: { modalHost.dismiss() },
                onConfirm: startOnboardingReplay
            )
        }
    }

    private func startOnboardingReplay() {
        guard !onboardingReplayState.isSaving, let presentationID = modalHost.presentationID else { return }
        let transaction = PickyHubOnboardingReplaySaveTransaction.begin(in: &settingsViewModel.settings)
        onboardingReplayTransaction = transaction
        onboardingReplayState = .saving
        settingsViewModel.save { succeeded in
            guard self.onboardingReplayTransaction == transaction,
                  self.modalHost.presentationID == presentationID
            else { return }
            if succeeded {
                self.onboardingReplayTransaction = nil
                self.onboardingReplayState = .idle
                self.modalHost.dismiss()
                self.dependencies.requestOnboardingReplay()
            } else {
                transaction.restoreAfterFailedSave(in: &self.settingsViewModel.settings)
                self.onboardingReplayTransaction = nil
                self.onboardingReplayState = .failed(
                    self.settingsViewModel.validationError ?? "Unable to save the onboarding preference."
                )
            }
        }
    }

    private func cancelOnboardingReplayIfNeeded() {
        guard let transaction = onboardingReplayTransaction else { return }
        transaction.restoreAfterFailedSave(in: &settingsViewModel.settings)
        onboardingReplayTransaction = nil
        onboardingReplayState = .idle
    }

    private func restoreOnboardingTrigger() {
        focusedSettingsControl = "onboarding"
    }

    private func presentStatisticsResetConfirmation() {
        modalHost.present(
            width: 430,
            accessibilityLabel: L10n.t("hub.settings.statisticsReset.dialog.title"),
            onDismiss: { focusedSettingsControl = "statisticsReset" }
        ) {
            PickyHubConfirmDialog(
                title: L10n.t("hub.settings.statisticsReset.dialog.title"),
                message: L10n.t("hub.settings.statisticsReset.dialog.message"),
                confirmTitle: "hub.settings.statisticsReset.dialog.confirm",
                onCancel: { modalHost.dismiss() },
                onConfirm: {
                    startStatisticsReset()
                    modalHost.dismiss()
                }
            )
        }
    }

    private func startStatisticsReset() {
        guard statisticsResetState != .pending else { return }
        statisticsResetState = .pending
        Task {
            await dependencies.statisticsStore.resetClassifications()
            guard !Task.isCancelled else { return }
            statisticsResetState = PickyHubStatisticsResetState.completed(with: dependencies.statisticsStore.state)
        }
    }
}

enum PickyHubOnboardingReplayState: Equatable {
    case idle
    case saving
    case failed(String)

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

private struct PickyHubOnboardingReplayConfirmation: View {
    @Binding var state: PickyHubOnboardingReplayState
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubConfirmDialog(
                title: L10n.t("hub.settings.onboarding.dialog.title"),
                message: L10n.t("hub.settings.onboarding.dialog.message"),
                confirmTitle: "hub.settings.onboarding.dialog.confirm",
                confirmRole: .primary,
                isBusy: state.isSaving,
                onCancel: onCancel,
                onConfirm: onConfirm
            )
            if let errorMessage = state.errorMessage {
                PickyHubInlineStatus(tone: .error, message: errorMessage)
                    .padding(.horizontal, PickyHubTheme.Spacing.cardInset)
                    .padding(.bottom, PickyHubTheme.Spacing.cardInset)
            }
        }
    }
}

enum PickyHubStatisticsResetState: Equatable {
    case idle
    case pending
    case success
    case failed(String)

    static func completed(with state: PickyHubStatisticsStore.State) -> Self {
        switch state {
        case .loaded:
            .success
        case .failed(let message):
            .failed(message)
        case .idle, .loading:
            .failed(L10n.t("hub.stats.error.generic"))
        }
    }
}

private struct PickyHubSettingsGroupSection<Content: View>: View {
    let group: PickyHubSettingsGroup
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                Text(group.titleKey)
                    .pickyFont(size: PickyHubTheme.Typography.greetingTitle, weight: .semibold)
                    .tracking(-0.5)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(group.subtitleKey)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()
            }
            content()
        }
        .padding(.top, PickyHubTheme.Layout.sectionSpacing)
        .scrollTargetLayout()
    }
}

enum PickyHubFontScaleTarget {
    case report
    case terminal
}

enum PickyHubSettingsControlMutation {
    static func setFontScale(_ target: PickyHubFontScaleTarget, to value: Double, in settings: inout PickySettings) {
        switch target {
        case .report:
            settings.fontScales.markdownReport = PickyFontScales.clamped(value)
        case .terminal:
            settings.fontScales.terminal = PickyFontScales.clamped(value)
        }
    }

    static func unpinFolder(_ path: String, in settings: inout PickySettings) {
        settings.unpinPickleCwd(path)
    }

    static func removeRecentFolder(_ path: String, in settings: inout PickySettings) {
        settings.removeRecentPickleCwd(path)
    }
}

private struct PickyHubSettingsBadgeLayout: Layout {
    let spacing: CGFloat
    let maximumItemsPerRow: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maximumWidth = proposal.width ?? .greatestFiniteMagnitude
        var lineWidth: CGFloat = 0
        var maximumLineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var itemsOnLine = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = lineWidth == 0 ? size.width : size.width + spacing
            let reachedItemLimit = itemsOnLine == maximumItemsPerRow
            if lineWidth > 0, reachedItemLimit || lineWidth + itemWidth > maximumWidth {
                maximumLineWidth = max(maximumLineWidth, lineWidth)
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
                itemsOnLine = 1
            } else {
                lineWidth += itemWidth
                lineHeight = max(lineHeight, size.height)
                itemsOnLine += 1
            }
        }

        maximumLineWidth = max(maximumLineWidth, lineWidth)
        return CGSize(width: proposal.width ?? maximumLineWidth, height: totalHeight + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var origin = bounds.origin
        var lineHeight: CGFloat = 0
        var itemsOnLine = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let reachedItemLimit = itemsOnLine == maximumItemsPerRow
            if origin.x > bounds.minX, reachedItemLimit || origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
                itemsOnLine = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            itemsOnLine += 1
        }
    }
}

private struct PickyHubSettingsGroupBadge: View {
    let group: PickyHubSettingsGroup
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var badgeShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PickyHubTheme.Control.minimumHeight / 2,
            style: .circular
        )
    }

    var body: some View {
        Button(action: action) {
            Text(group.titleKey)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.textSecondary)
                .padding(.horizontal, PickyHubTheme.Control.horizontalInset)
                .frame(minHeight: PickyHubTheme.Control.minimumHeight)
                .background(
                    badgeShape
                        .fill(isHovering ? PickyHubTheme.Colors.navHighlight : Color.clear)
                )
                .overlay(
                    badgeShape
                        .strokeBorder(
                            isSelected || isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.borderSoft,
                            lineWidth: 1
                        )
                )
                .contentShape(badgeShape)
        }
        .buttonStyle(PickyHubPressStyle())
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Radius.pill)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.hover, value: isHovering)
        .accessibilityLabel(Text(group.titleKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PickyHubSettingsScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void

    func makeNSView(context: Context) -> PickyHubSettingsScrollHostView {
        let view = PickyHubSettingsScrollHostView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: PickyHubSettingsScrollHostView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolve()
    }

    static func dismantleNSView(_ nsView: PickyHubSettingsScrollHostView, coordinator: ()) {
        nsView.onResolve = nil
    }
}

private final class PickyHubSettingsScrollHostView: NSView {
    var onResolve: ((NSScrollView) -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolve()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolve()
    }

    func resolve() {
        guard let scrollView = enclosingScrollView else { return }
        onResolve?(scrollView)
    }
}

@MainActor
private final class PickyHubSettingsScrollCoordinator {
    private weak var scrollView: NSScrollView?

    func attach(to scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    func align(targetOffset: CGFloat, below clearance: CGFloat) -> Bool {
        guard targetOffset < clearance - 0.5, let scrollView else { return false }
        let clipView = scrollView.contentView
        let currentOrigin = clipView.bounds.origin
        let minimumY = -scrollView.contentInsets.top
        let adjustedY = max(minimumY, currentOrigin.y - (clearance - targetOffset))
        clipView.scroll(to: CGPoint(x: currentOrigin.x, y: adjustedY))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

private struct PickyHubSettingsGroupOffsetPreference: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct PickyHubSettingsNavigationHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum PickyHubSettingsLayout {
    /// Seven badges read as a balanced 4 + 3 directory instead of leaving an orphan on wide layouts.
    static let maximumBadgesPerRow = 4
    /// Bounds native popup menus without changing the width of other row controls.
    static let nativeMenuWidth: CGFloat = 180
    static let stackedRowMinimumWidth: CGFloat = 560
}

private extension View {
    func pickyHubSettingsNativeMenuWidth() -> some View {
        frame(width: PickyHubSettingsLayout.nativeMenuWidth, alignment: .trailing)
    }
}

private struct PickyHubGeneralControls: View {
    @ObservedObject private var localeManager = LocaleManager.shared
    @ObservedObject var settingsViewModel: PickySettingsViewModel
    @ObservedObject var appearanceStore: PickyAppearanceStore
    @ObservedObject var fontScaleStore: PickyAppFontScaleStore
    @ObservedObject var updaterController: PickyUpdaterController
    let focusedControl: FocusState<String?>.Binding
    let replayOnboarding: () -> Void

    var body: some View {
        PickyHubSettingsList {
            PickyHubSettingsRow(title: "hub.settings.appearance", detail: "hub.settings.appearance.detail") {
                PickyHubMenuPicker(
                    title: menuTitle("hub.settings.appearance"),
                    selection: Binding(get: { appearanceStore.mode }, set: appearanceStore.setMode),
                    options: PickyAppearanceMode.allCases.map { mode in
                        .init(value: mode, title: mode == .light ? menuTitle("hub.settings.appearance.light") : menuTitle("hub.settings.appearance.dark"))
                    }
                )
                .pickyHubSettingsNativeMenuWidth()
            }
            PickyHubSettingsRow(title: "hub.settings.fontScale", detail: "hub.settings.fontScale.detail") {
                PickyHubMenuPicker(
                    title: menuTitle("hub.settings.fontScale"),
                    selection: Binding(get: { fontScaleStore.scale }, set: fontScaleStore.setScale),
                    options: [0.9, 1.0, 1.1, 1.2, 1.3].map { .init(value: $0, title: "\(Int($0 * 100))%") }
                )
                .pickyHubSettingsNativeMenuWidth()
            }
            fontScaleRow(title: "hub.settings.reportFontScale", detail: "hub.settings.reportFontScale.detail", target: .report)
            fontScaleRow(title: "hub.settings.terminalFontScale", detail: "hub.settings.terminalFontScale.detail", target: .terminal)
            PickyHubSettingsRow(title: "hub.settings.updateChannel", detail: "hub.settings.updateChannel.detail") {
                PickyHubMenuPicker(
                    title: menuTitle("hub.settings.updateChannel"),
                    selection: $settingsViewModel.settings.updateChannel,
                    options: PickyUpdateChannel.allCases.map { .init(value: $0, title: $0.displayName) }
                )
                .pickyHubSettingsNativeMenuWidth()
                .onChange(of: settingsViewModel.settings.updateChannel) { _, _ in settingsViewModel.save() }
            }
            PickyHubSettingsRow(title: "hub.settings.autoUpdates", detail: "hub.settings.autoUpdates.detail") {
                Toggle("hub.settings.autoUpdates", isOn: Binding(
                    get: { settingsViewModel.settings.updatesAutomaticChecksEnabled },
                    set: { enabled in
                        settingsViewModel.settings.updatesAutomaticChecksEnabled = enabled
                        updaterController.updateAutomaticChecksPreference(enabled)
                        settingsViewModel.save()
                    }
                ))
                .labelsHidden().toggleStyle(.switch).tint(PickyHubTheme.Colors.action)
            }
            PickyHubSettingsRow(title: "hub.settings.checkUpdates", detail: "hub.settings.checkUpdates.detail") {
                PickyHubButton(title: "hub.settings.checkUpdates.action", role: .secondary, isEnabled: updaterController.isAvailable && updaterController.canCheckForUpdates, action: updaterController.checkForUpdates)
            }
            PickyHubSettingsRow(title: "hub.settings.onboarding", detail: "hub.settings.onboarding.detail") {
                PickyHubButton(title: "hub.settings.onboarding.action", role: .secondary, action: replayOnboarding)
                    .focused(focusedControl, equals: "onboarding")
            }
        }
    }

    private func menuTitle(_ key: String) -> String {
        NSLocalizedString(key, bundle: localeManager.stringsBundle, value: key, comment: "")
    }

    private func fontScaleRow(title: String, detail: LocalizedStringKey, target: PickyHubFontScaleTarget) -> some View {
        PickyHubSettingsRow(title: LocalizedStringKey(title), detail: detail) {
            PickyHubMenuPicker(title: menuTitle(title), selection: Binding(
                get: {
                    switch target {
                    case .report: settingsViewModel.settings.fontScales.markdownReport
                    case .terminal: settingsViewModel.settings.fontScales.terminal
                    }
                },
                set: { value in
                    PickyHubSettingsControlMutation.setFontScale(target, to: value, in: &settingsViewModel.settings)
                    settingsViewModel.save()
                }
            ), options: (7...25).map { .init(value: Double($0) / 10, title: "\($0 * 10)%") })
            .pickyHubSettingsNativeMenuWidth()
        }
    }
}

private struct PickyHubPickleFolderControls: View {
    @ObservedObject var settingsViewModel: PickySettingsViewModel

    var body: some View {
        PickyHubSettingsList {
            folderRow(
                title: "hub.settings.pinnedFolders",
                detail: "hub.settings.pinnedFolders.detail",
                folders: settingsViewModel.settings.pinnedPickleCwds,
                actionTitle: "hub.settings.pinnedFolders.unpin",
                action: unpin
            )
            folderRow(
                title: "hub.settings.recentFolders",
                detail: "hub.settings.recentFolders.detail",
                folders: settingsViewModel.settings.recentPickleCwds,
                actionTitle: "hub.settings.recentFolders.remove",
                action: removeRecent
            )
        }
    }

    private func folderRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        folders: [String],
        actionTitle: LocalizedStringKey,
        action: @escaping (String) -> Void
    ) -> some View {
        PickyHubSettingsRow(title: title, detail: detail) {
            VStack(alignment: .trailing, spacing: DS.Spacing.space2) {
                if folders.isEmpty {
                    Text("hub.settings.folders.empty")
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .pickyHubSelectableText()
                } else {
                    ForEach(folders, id: \.self) { path in
                        let contextualActionLabel = Text(actionTitle) + Text(": ") + Text(path)
                        HStack(spacing: DS.Spacing.space1) {
                            Text(path)
                                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium, design: .monospaced)
                                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .pickyHubSelectableText()
                            Button(action: { action(path) }) {
                                Image(systemName: "xmark")
                                    .pickyFont(size: 10, weight: .semibold)
                                    .frame(
                                        width: PickyHubTheme.Control.minimumHeight,
                                        height: PickyHubTheme.Control.minimumHeight
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(PickyHubTheme.Colors.textTertiary)
                            .help(contextualActionLabel)
                            .accessibilityLabel(contextualActionLabel)
                        }
                    }
                }
            }
        }
    }

    private func unpin(_ path: String) {
        PickyHubSettingsControlMutation.unpinFolder(path, in: &settingsViewModel.settings)
        settingsViewModel.save()
    }

    private func removeRecent(_ path: String) {
        PickyHubSettingsControlMutation.removeRecentFolder(path, in: &settingsViewModel.settings)
        settingsViewModel.save()
    }
}

private struct PickyHubNotificationControls: View {
    @ObservedObject var settingsViewModel: PickySettingsViewModel

    var body: some View {
        PickyHubSettingsList {
            notificationRow("hub.settings.notification.main", detail: "hub.settings.notification.main.detail", binding: \PickyNotificationPreferences.notifyMainOnCompletionForNewPickles)
            notificationRow("hub.settings.notification.completion", detail: "hub.settings.notification.completion.detail", binding: \PickyNotificationPreferences.notifyMacOSOnCompletionForNewPickles)
            notificationRow("hub.settings.notification.failure", detail: "hub.settings.notification.failure.detail", binding: \PickyNotificationPreferences.notifyOnFailed)
            notificationRow("hub.settings.notification.input", detail: "hub.settings.notification.input.detail", binding: \PickyNotificationPreferences.notifyOnWaitingForInput)
        }
    }

    private func notificationRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, binding: WritableKeyPath<PickyNotificationPreferences, Bool>) -> some View {
        PickyHubSettingsRow(title: title, detail: detail) {
            Toggle(title, isOn: Binding(
                get: { settingsViewModel.settings.notifications[keyPath: binding] },
                set: { enabled in
                    settingsViewModel.settings.notifications[keyPath: binding] = enabled
                    settingsViewModel.save()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(PickyHubTheme.Colors.action)
        }
    }
}

private struct PickyHubPermissionRows: View {
    @ObservedObject var permissions: PickyPermissionMonitor

    var body: some View {
        PickyHubSettingsList {
            permissionRow(
                "hub.settings.permission.screen",
                target: .screenRecording,
                granted: permissions.hasScreenRecording
            )
            permissionRow(
                "hub.settings.permission.microphone",
                target: .microphone,
                granted: permissions.hasMicrophone
            )
            permissionRow(
                "hub.settings.permission.accessibility",
                target: .accessibility,
                granted: permissions.hasAccessibility
            )
            permissionRow(
                "hub.settings.permission.browser",
                target: .browserContent,
                granted: permissions.hasScreenContent,
                isBusy: permissions.isRequestingScreenContent
            )
        }
    }

    private func permissionRow(
        _ title: LocalizedStringKey,
        target: PickyHubPermissionTarget,
        granted: Bool,
        isBusy: Bool = false
    ) -> some View {
        let action = PickyHubPermissionAction.resolve(target: target, isGranted: granted)
        return PickyHubSettingsRow(title: title, detail: "hub.settings.permission.detail") {
            PickyHubButton(
                title: granted ? "hub.settings.permission.granted" : "hub.settings.permission.required",
                role: .secondary,
                systemImage: granted ? "checkmark.circle" : action.systemImage,
                isBusy: isBusy,
                action: {
                    action.perform(
                        openSystemSettings: { NSWorkspace.shared.open($0) },
                        requestScreenContent: permissions.requestScreenContent
                    )
                }
            )
        }
    }
}

private extension PickyHubPermissionAction {
    var systemImage: String {
        switch self {
        case .openSystemSettings: "gear"
        case .requestScreenContent: "eye"
        }
    }
}

private struct PickyHubAdvancedControls: View {
    @ObservedObject var settingsViewModel: PickySettingsViewModel
    let focusedControl: FocusState<String?>.Binding
    let resetStatistics: () -> Void
    let resetState: PickyHubStatisticsResetState

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            PickyHubSettingsList {
                PickyHubSettingsRow(title: "hub.settings.watchdog", detail: "hub.settings.watchdog.detail") {
                    Toggle("hub.settings.watchdog", isOn: Binding(
                        get: { settingsViewModel.settings.mainThreadWatchdogEnabled },
                        set: { enabled in settingsViewModel.settings.mainThreadWatchdogEnabled = enabled; settingsViewModel.save() }
                    ))
                    .labelsHidden().toggleStyle(.switch).tint(PickyHubTheme.Colors.action)
                }
                PickyHubSettingsRow(title: "hub.settings.shellCommand", detail: "hub.settings.shellCommand.detail") {
                    PickyHubButton(title: "hub.settings.shellCommand.action", role: .secondary, systemImage: "terminal", action: {
                        ShellCommandMenuController.shared.showInstallerAlert()
                    })
                }
                PickyHubSettingsRow(title: "hub.settings.statisticsReset", detail: "hub.settings.statisticsReset.detail") {
                    PickyHubButton(
                        title: "hub.settings.statisticsReset.action",
                        role: .danger,
                        isBusy: resetState == .pending,
                        isEnabled: resetState != .pending,
                        action: resetStatistics
                    )
                    .focused(focusedControl, equals: "statisticsReset")
                }
            }
            resetStatus
        }
    }

    @ViewBuilder
    private var resetStatus: some View {
        switch resetState {
        case .idle:
            EmptyView()
        case .pending:
            PickyHubInlineStatus(tone: .neutral, message: L10n.t("hub.settings.statisticsReset.pending"))
        case .success:
            PickyHubInlineStatus(tone: .success, message: L10n.t("hub.settings.statisticsReset.success"))
        case .failed(let message):
            PickyHubInlineStatus(tone: .error, message: message)
        }
    }
}

private struct PickyHubSettingsList<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .pickyHubCard(radius: PickyHubTheme.Radius.card)
    }
}

private struct PickyHubSettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let control: () -> Control
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        Group {
            if contentWidth < PickyHubSettingsLayout.stackedRowMinimumWidth * fontScale {
                VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                    labels
                    control()
                        .frame(maxWidth: PickyHubTheme.Control.maximumFieldWidth, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: PickyHubTheme.Spacing.field) {
                    labels
                    Spacer(minLength: PickyHubTheme.Spacing.related)
                    control()
                        .frame(
                            minWidth: PickyHubTheme.Control.maximumFieldWidth / 2,
                            maxWidth: PickyHubTheme.Control.maximumFieldWidth,
                            alignment: .trailing
                        )
                }
            }
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .overlay(alignment: .bottom) { Divider().overlay(PickyHubTheme.Colors.borderSoft) }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            Text(detail)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
        }
    }
}

private struct PickyHubSettingsDisclosure<Content: View>: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    let onExpandedContentAppear: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content()
                .padding(.top, DS.Spacing.space2)
                .onAppear(perform: onExpandedContentAppear)
        } label: {
            Text(title).pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold).foregroundColor(PickyHubTheme.Colors.textSecondary)
        }
        .disclosureGroupStyle(PickySettingsDisclosureStyle())
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.surface)
    }
}

private struct PickyHubSettingsNotice: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
            .foregroundColor(PickyHubTheme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .pickyHubSelectableText()
            .padding(PickyHubTheme.Spacing.cardInset)
            .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.surface)
    }
}

private extension PickyHubSettingsGroup {
    var titleKey: LocalizedStringKey {
        let key: String = "hub.settings.group.\(rawValue).title"
        return LocalizedStringKey(key)
    }
    var subtitleKey: LocalizedStringKey {
        let key: String = "hub.settings.group.\(rawValue).subtitle"
        return LocalizedStringKey(key)
    }
}
