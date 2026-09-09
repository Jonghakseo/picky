//
//  PickyHubRootView.swift
//  Picky
//
//  Window content: sidebar + retained page host. Pages mount on first visit
//  and then stay alive, preserving scroll position and transient state without
//  constructing every Hub page during window focus.
//

import Combine
import SwiftUI

struct PickyHubRootView: View {
    let dependencies: PickyHubDependencies
    @ObservedObject private var navigator: PickyHubNavigator
    @ObservedObject private var modalHost: PickyHubModalHost
    @ObservedObject private var settingsViewModel: PickySettingsViewModel
    @StateObject private var pageMountLifecycle: PickyHubPageMountLifecycle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedSidebarControl: String?
    let dockDisplayIDProvider: () -> CGDirectDisplayID?

    init(dependencies: PickyHubDependencies, dockDisplayIDProvider: @escaping () -> CGDirectDisplayID?) {
        self.dependencies = dependencies
        self.dockDisplayIDProvider = dockDisplayIDProvider
        _navigator = ObservedObject(wrappedValue: dependencies.navigator)
        _modalHost = ObservedObject(wrappedValue: dependencies.modalHost)
        _settingsViewModel = ObservedObject(wrappedValue: dependencies.settingsViewModel)
        _pageMountLifecycle = StateObject(
            wrappedValue: PickyHubPageMountLifecycle(initialPage: dependencies.navigator.selectedPage)
        )
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
                    focusedControl: $focusedSidebarControl,
                    onFeedbackTapped: presentFeedback
                )

                GeometryReader { viewport in
                    PickyHubRetainedPageHost(
                        lifecycle: pageMountLifecycle,
                        selectedPage: navigator.selectedPage
                    ) { page in
                        pageView(page)
                            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                    }
                    .environment(\.pickyHubContentWidth, PickyHubGridPolicy.contentWidth(forViewportWidth: viewport.size.width))
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                }
                .background(PickyHubTheme.Colors.canvas)
                .animation(reduceMotion ? nil : PickyHubTheme.Motion.page, value: navigator.selectedPage)
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
        .task(id: navigator.shouldRefreshStatistics) {
            guard navigator.shouldRefreshStatistics else { return }
            while !Task.isCancelled {
                dependencies.statisticsStore.refreshIfNeeded()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
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
        modalHost.present(
            width: 480,
            accessibilityLabel: L10n.t("settings.section.feedback.title"),
            onDismiss: { focusedSidebarControl = "feedback" }
        ) {
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
