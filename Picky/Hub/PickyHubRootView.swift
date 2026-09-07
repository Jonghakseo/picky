//
//  PickyHubRootView.swift
//  Picky
//
//  Window content: sidebar + one page host. Every page stays mounted inside a
//  ZStack and is only hidden when not selected, so each page keeps its own
//  scroll position and transient state while the user moves around.
//

import Combine
import SwiftUI

struct PickyHubRootView: View {
    let dependencies: PickyHubDependencies
    @ObservedObject private var navigator: PickyHubNavigator
    @ObservedObject private var modalHost: PickyHubModalHost
    @ObservedObject private var settingsViewModel: PickySettingsViewModel
    let dockDisplayIDProvider: () -> CGDirectDisplayID?

    init(dependencies: PickyHubDependencies, dockDisplayIDProvider: @escaping () -> CGDirectDisplayID?) {
        self.dependencies = dependencies
        self.dockDisplayIDProvider = dockDisplayIDProvider
        _navigator = ObservedObject(wrappedValue: dependencies.navigator)
        _modalHost = ObservedObject(wrappedValue: dependencies.modalHost)
        _settingsViewModel = ObservedObject(wrappedValue: dependencies.settingsViewModel)
    }

    private var restartRequirement: PickyRestartRequirement {
        PickyRestartSettingsSnapshotStore.requirement(for: settingsViewModel.settings)
    }

    var body: some View {
        PickyHubModalOverlay(host: modalHost) {
            HStack(spacing: 0) {
                PickyHubSidebarView(
                    navigator: navigator,
                    restartRequirement: restartRequirement,
                    dockDisplayIDProvider: dockDisplayIDProvider,
                    onFeedbackTapped: presentFeedback
                )

                ZStack {
                    ForEach(PickyHubPage.allCases) { page in
                        pageView(page)
                            .opacity(navigator.selectedPage == page ? 1 : 0)
                            .allowsHitTesting(navigator.selectedPage == page)
                            .accessibilityHidden(navigator.selectedPage != page)
                            .disabled(navigator.selectedPage != page)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PickyHubTheme.Colors.canvas)
                .animation(PickyHubTheme.Motion.page, value: navigator.selectedPage)
            }
        }
        .frame(
            minWidth: PickyHubTheme.Layout.minimumWindowSize.width,
            minHeight: PickyHubTheme.Layout.minimumWindowSize.height
        )
        .background(PickyHubTheme.Colors.canvas)
        .environmentObject(navigator)
        .environmentObject(modalHost)
        .environmentObject(dependencies.statisticsStore)
        .environmentObject(dependencies.quickStartLauncher)
        .environmentObject(dependencies.pluginCatalog)
    }

    @ViewBuilder
    private func pageView(_ page: PickyHubPage) -> some View {
        switch page {
        case .dashboard:
            PickyHubDashboardPage(dependencies: dependencies)
        case .statistics:
            PickyHubStatisticsPage(dependencies: dependencies)
        case .guides:
            PickyHubGuidesPage(dependencies: dependencies)
        case .quickStart:
            PickyHubQuickStartPage(dependencies: dependencies)
        case .plugins:
            PickyHubPluginsPage(dependencies: dependencies)
        case .conversation:
            PickyHubConversationPage(dependencies: dependencies)
        case .settings:
            PickyHubSettingsPage(dependencies: dependencies)
        }
    }

    private func presentFeedback() {
        let viewModel = settingsViewModel
        modalHost.present(width: 480, accessibilityLabel: L10n.t("settings.section.feedback.title")) {
            PickyHubFeedbackDialog(viewModel: viewModel)
        }
    }
}

/// Feedback form wrapped in the hub dialog chrome.
struct PickyHubFeedbackDialog: View {
    @ObservedObject var viewModel: PickySettingsViewModel
    @EnvironmentObject private var modalHost: PickyHubModalHost

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PickyHubModalHeader(
                meta: L10n.t("settings.section.feedback.subtitle"),
                title: L10n.t("settings.section.feedback.title"),
                onClose: { modalHost.dismiss() }
            )
            CompanionPanelFeedbackView(viewModel: viewModel)
        }
        .padding(20)
    }
}
