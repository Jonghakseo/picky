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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var statisticsResetState: PickyHubStatisticsResetState = .idle
    @State private var onboardingReplayState: PickyHubOnboardingReplayState = .idle
    @State private var onboardingReplayTransaction: PickyHubOnboardingReplaySaveTransaction?
    @State private var settingsNavigationState = PickyHubSettingsNavigationState()
    @State private var pendingDisclosureScrollTarget: String?
    @FocusState private var focusedSettingsControl: String?

    init(dependencies: PickyHubDependencies) {
        self.dependencies = dependencies
        _settingsViewModel = ObservedObject(wrappedValue: dependencies.settingsViewModel)
        _permissions = ObservedObject(wrappedValue: dependencies.permissions)
    }

    var body: some View {
        ScrollViewReader { proxy in
            PickyHubPageScroll {
                PickyHubPageHeader(title: PickyHubPage.settings.titleKey, subtitle: "hub.page.settings.subtitle")
                groupLinks(proxy)
                if restartRequired {
                    PickyHubInlineStatus(
                        tone: .warning,
                        message: L10n.t("hub.settings.restart.message"),
                        actionTitle: "hub.settings.restart.action",
                        action: { PickyRelauncher.relaunchAndTerminate() }
                    )
                    .padding(.bottom, 12)
                }
                ForEach(PickyHubSettingsGroup.allCases) { group in
                    PickyHubSettingsGroupSection(group: group) {
                        groupContent(group, scrollProxy: proxy)
                    }
                    .id(group.id)
                }
            }
            .environment(\.pickyUsesSubtleMenuChrome, true)
            .onAppear { consumePendingSettingsNavigation(with: proxy) }
            .onChange(of: navigator.pendingSettingsNavigation) { _, _ in
                consumePendingSettingsNavigation(with: proxy)
            }
        }
    }

    private var restartRequired: Bool {
        PickyRestartSettingsSnapshotStore.requirement(for: settingsViewModel.settings).isRequired
    }

    private func groupLinks(_ proxy: ScrollViewProxy) -> some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(
                        minimum: PickyHubSettingsLayout.groupLinkMinimumWidth,
                        maximum: PickyHubSettingsLayout.groupLinkMaximumWidth
                    ),
                    spacing: DS.Spacing.space2,
                    alignment: .leading
                )
            ],
            alignment: .leading,
            spacing: DS.Spacing.space2
        ) {
            ForEach(PickyHubSettingsGroup.allCases) { group in
                Button {
                    scrollTo(group.id, with: proxy)
                } label: {
                    Text(group.titleKey)
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PickyHubSettingsJumpStyle())
            }
        }
        .accessibilityLabel(Text("hub.settings.groupLinks"))
        .padding(.bottom, DS.Spacing.space4)
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
                .padding(DS.Spacing.space4)
                .pickyHubCard()
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
        withAnimation(reduceMotion ? nil : PickyHubTheme.Motion.page) {
            proxy.scrollTo(target, anchor: .top)
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
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
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
        VStack(alignment: .leading, spacing: DS.Spacing.space4) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space2) {
                Text(group.titleKey)
                    .pickyFont(size: PickyHubTheme.Typography.greetingTitle, weight: .semibold)
                    .tracking(-0.5)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(group.subtitleKey)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
            }
            content()
        }
        .padding(.top, DS.Spacing.space6)
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

/// Keep long localized jump labels visible; AppKit's bordered button truncates
/// them even when the SwiftUI label requests multiple lines.
private struct PickyHubSettingsJumpStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isHovered ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.textSecondary)
            .padding(DS.Spacing.space2)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(configuration.isPressed || isHovered ? PickyHubTheme.Colors.navHighlight : PickyHubTheme.Colors.surface)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous))
            .onHover { isHovered = $0 }
    }
}

private enum PickyHubSettingsLayout {
    static let groupLinkMinimumWidth: CGFloat = 156
    static let groupLinkMaximumWidth: CGFloat = 176
    /// Bounds native popup menus without changing the width of other row controls.
    static let nativeMenuWidth: CGFloat = 180
    static let compactIconHitTarget: CGFloat = 28
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
                PickyNativeMenuPicker(
                    title: menuTitle("hub.settings.appearance"),
                    selection: Binding(get: { appearanceStore.mode }, set: appearanceStore.setMode),
                    options: PickyAppearanceMode.allCases.map { mode in
                        .init(value: mode, title: mode == .light ? menuTitle("hub.settings.appearance.light") : menuTitle("hub.settings.appearance.dark"))
                    }
                )
                .pickyHubSettingsNativeMenuWidth()
            }
            PickyHubSettingsRow(title: "hub.settings.fontScale", detail: "hub.settings.fontScale.detail") {
                PickyNativeMenuPicker(
                    title: menuTitle("hub.settings.fontScale"),
                    selection: Binding(get: { fontScaleStore.scale }, set: fontScaleStore.setScale),
                    options: [0.9, 1.0, 1.1, 1.2, 1.3].map { .init(value: $0, title: "\(Int($0 * 100))%") }
                )
                .pickyHubSettingsNativeMenuWidth()
            }
            fontScaleRow(title: "hub.settings.reportFontScale", detail: "hub.settings.reportFontScale.detail", target: .report)
            fontScaleRow(title: "hub.settings.terminalFontScale", detail: "hub.settings.terminalFontScale.detail", target: .terminal)
            PickyHubSettingsRow(title: "hub.settings.updateChannel", detail: "hub.settings.updateChannel.detail") {
                PickyNativeMenuPicker(
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
            PickyNativeMenuPicker(title: menuTitle(title), selection: Binding(
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
                } else {
                    ForEach(folders, id: \.self) { path in
                        let contextualActionLabel = Text(actionTitle) + Text(": ") + Text(path)
                        HStack(spacing: DS.Spacing.space1) {
                            Text(path)
                                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium, design: .monospaced)
                                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(action: { action(path) }) {
                                Image(systemName: "xmark")
                                    .pickyFont(size: 10, weight: .bold)
                                    .frame(
                                        width: PickyHubSettingsLayout.compactIconHitTarget,
                                        height: PickyHubSettingsLayout.compactIconHitTarget
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
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
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

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.space4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold).foregroundColor(PickyHubTheme.Colors.textPrimary)
                Text(detail).pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular).foregroundColor(PickyHubTheme.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control().frame(minWidth: 160, alignment: .trailing)
        }
        .padding(.horizontal, DS.Spacing.space4)
        .padding(.vertical, DS.Spacing.space3)
        .overlay(alignment: .bottom) { Divider().overlay(PickyHubTheme.Colors.borderSoft) }
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
        .padding(DS.Spacing.space4)
        .pickyHubCard(fill: PickyHubTheme.Colors.surface)
    }
}

private struct PickyHubSettingsNotice: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
            .foregroundColor(PickyHubTheme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DS.Spacing.space4)
            .pickyHubCard(fill: PickyHubTheme.Colors.surface)
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
