//
//  PickyHubSettingsGroupingTests.swift
//  PickyTests
//

import Foundation
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHubSettingsGroupingTests {
    @Test func keepsSettingsGroupsInMockupOrder() {
        #expect(PickyHubSettingsGroup.allCases == [
            .general,
            .agents,
            .voice,
            .overlay,
            .workspace,
            .privacy,
            .advanced,
        ])
    }

    @Test(arguments: [
        (CompanionPanelSettingsRoute.general, PickyHubSettingsGroup.general),
        (.onboarding, .general),
        (.oauth, .agents),
        (.mainAgent, .agents),
        (.builtinTools, .agents),
        (.voice, .voice),
        (.shortcuts, .voice),
        (.overlayAndNotifications, .overlay),
        (.pickle, .workspace),
    ])
    func mapsLegacySettingsRoutesToTheirHubGroups(
        route: CompanionPanelSettingsRoute,
        expectedGroup: PickyHubSettingsGroup
    ) {
        #expect(PickyHubSettingsGroup.hosting(route) == expectedGroup)
    }

    @Test func routesSettingsDeepLinksToTheMappedGroup() {
        let navigator = PickyHubNavigator()

        navigator.apply(deepLink: PickyDeepLink(tab: .settings, settingsRoute: .voice))

        #expect(navigator.selectedPage == .settings)
        #expect(navigator.pendingSettingsGroup == .voice)
    }

    @Test func legacyLeafLinksReachTheRenderedGroupAnchorAndDisclosure() throws {
        let navigator = PickyHubNavigator()
        var renderedState = PickyHubSettingsNavigationState()

        let toolsURL = try #require(URL(string: "picky://settings/tools"))
        let toolsLink = try #require(PickyDeepLink(url: toolsURL))
        navigator.apply(deepLink: toolsLink)
        let firstToolsRequest = try #require(navigator.consumePendingSettingsNavigation())
        #expect(firstToolsRequest.group == .agents)
        #expect(firstToolsRequest.leaf == .builtinTools)
        #expect(
            renderedState.apply(firstToolsRequest)
                == PickyHubSettingsLeaf.builtinTools.scrollTargetID
        )
        #expect(renderedState.isExpanded(.agentTools))

        navigator.apply(deepLink: toolsLink)
        let repeatedToolsRequest = try #require(navigator.consumePendingSettingsNavigation())
        #expect(repeatedToolsRequest.id != firstToolsRequest.id)
        #expect(
            renderedState.apply(repeatedToolsRequest)
                == PickyHubSettingsLeaf.builtinTools.scrollTargetID
        )
        #expect(renderedState.isExpanded(.agentTools))

        let notificationURL = try #require(URL(string: "picky://settings/notification"))
        let notificationLink = try #require(PickyDeepLink(url: notificationURL))
        navigator.apply(deepLink: notificationLink)
        let notificationRequest = try #require(navigator.consumePendingSettingsNavigation())
        #expect(notificationRequest.group == .privacy)
        #expect(notificationRequest.leaf == .notifications)
        #expect(
            renderedState.apply(notificationRequest)
                == PickyHubSettingsLeaf.notifications.scrollTargetID
        )

        let cursorURL = try #require(URL(string: "picky://settings/cursorBubbles"))
        let cursorLink = try #require(PickyDeepLink(url: cursorURL))
        navigator.apply(deepLink: cursorLink)
        let cursorRequest = try #require(navigator.consumePendingSettingsNavigation())
        #expect(cursorRequest.group == .overlay)
        #expect(cursorRequest.leaf == .cursorBubbles)
        #expect(
            renderedState.apply(cursorRequest)
                == PickyHubSettingsLeaf.cursorBubbles.scrollTargetID
        )
    }

    @Test func ungrantedBrowserPermissionDispatchesToTheScreenContentOwner() throws {
        let action = PickyHubPermissionAction.resolve(target: .browserContent, isGranted: false)
        #expect(action == .requestScreenContent)

        var openedSettingsURLs: [URL] = []
        var screenContentRequests = 0
        action.perform(
            openSystemSettings: { openedSettingsURLs.append($0) },
            requestScreenContent: { screenContentRequests += 1 }
        )
        #expect(openedSettingsURLs.isEmpty)
        #expect(screenContentRequests == 1)

        let microphoneAction = PickyHubPermissionAction.resolve(
            target: .microphone,
            isGranted: false
        )
        microphoneAction.perform(
            openSystemSettings: { openedSettingsURLs.append($0) },
            requestScreenContent: { screenContentRequests += 1 }
        )
        let microphoneURL = try #require(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        )
        #expect(openedSettingsURLs == [microphoneURL])
        #expect(screenContentRequests == 1)
    }

    @Test func screenContentGrantPublishedByItsOwnerUpdatesTheHubPermissionState() {
        var persistedScreenContent = false
        var probes = PickyPermissionMonitor.Probes()
        probes.accessibility = { true }
        probes.screenRecording = { true }
        probes.microphone = { true }
        probes.persistedScreenContent = { persistedScreenContent }
        probes.persistScreenContent = { persistedScreenContent = true }
        let monitor = PickyPermissionMonitor(probes: probes)
        monitor.refresh()
        #expect(!monitor.hasScreenContent)

        let action = PickyHubPermissionAction.resolve(
            target: .browserContent,
            isGranted: monitor.hasScreenContent
        )
        action.perform(
            openSystemSettings: { _ in
                Issue.record("Browser content must not use a generic settings URL while ungranted")
            },
            requestScreenContent: { monitor.markScreenContentGranted() }
        )

        #expect(monitor.hasScreenContent)
        #expect(monitor.allGranted)
        #expect(persistedScreenContent)
    }

    @Test func embeddedRoutePresentationKeepsOnlyTheHubOwnedControlsAndSaveStatus() {
        #expect(!CompanionPanelSettingsPresentation.embedded.showsNavigationChrome)
        #expect(!CompanionPanelSettingsPresentation.embedded.showsSectionChrome)
        #expect(!CompanionPanelSettingsPresentation.embedded.includesShellCommandControl)
        #expect(!CompanionPanelSettingsPresentation.embeddedOverlayControls.includesOverlayNotificationControls)
        #expect(CompanionPanelSettingsPresentation.navigation.showsNavigationChrome)
        #expect(CompanionPanelSettingsPresentation.navigation.showsSectionChrome)
        #expect(CompanionPanelSettingsPresentation.navigation.includesShellCommandControl)
        #expect(CompanionPanelSettingsPresentation.navigation.includesOverlayNotificationControls)
    }

    @Test func statisticsResetOnlyBecomesSuccessfulAfterALoadedResponse() {
        #expect(PickyHubStatisticsResetState.completed(with: .loaded(.empty)) == .success)
        #expect(PickyHubStatisticsResetState.completed(with: .failed("daemon unavailable")) == .failed("daemon unavailable"))
        #expect(PickyHubStatisticsResetState.completed(with: .loading) != .success)
    }

    @Test func hubFontAndFolderControlsPersistUsingTheSettingsViewModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-hub-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let pinned = root.appendingPathComponent("pinned", isDirectory: true)
        let recent = root.appendingPathComponent("recent", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)

        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.mainAgentCwd = project.path
        settings.worktreeParent = project.path
        settings.pinPickleCwd(pinned.path)
        settings.recordRecentPickleCwd(recent.path)
        try store.save(settings)

        let viewModel = PickySettingsViewModel(store: store)
        PickyHubSettingsControlMutation.setFontScale(.report, to: 1.4, in: &viewModel.settings)
        PickyHubSettingsControlMutation.setFontScale(.terminal, to: 1.8, in: &viewModel.settings)
        PickyHubSettingsControlMutation.unpinFolder(pinned.path, in: &viewModel.settings)
        PickyHubSettingsControlMutation.removeRecentFolder(recent.path, in: &viewModel.settings)

        #expect(await viewModel.saveDurably())

        let saved = store.load()
        #expect(saved.fontScales.markdownReport == 1.4)
        #expect(saved.fontScales.terminal == 1.8)
        #expect(saved.pinnedPickleCwds.isEmpty)
        #expect(saved.recentPickleCwds == [pinned.path])
    }

    @Test func mountedHubRoutesInitializeAndObserveOnlyTheirOwnedSettings() {
        let hubRoutes: [CompanionPanelSettingsRoute] = [
            .general,
            .oauth,
            .mainAgent,
            .builtinTools,
            .voice,
            .shortcuts,
            .overlayAndNotifications,
            .pickle
        ]

        for route in hubRoutes {
            #expect(
                CompanionPanelSettingsOwnership.owns(
                    .ttsEnabled,
                    on: route,
                    presentation: .embedded
                ) == (route == .voice)
            )
            #expect(
                CompanionPanelSettingsOwnership.owns(
                    .disabledBuiltinTools,
                    on: route,
                    presentation: .embedded
                ) == (route == .builtinTools)
            )
            #expect(
                CompanionPanelSettingsOwnership.owns(
                    .cursor,
                    on: route,
                    presentation: .embedded
                ) == (route == .overlayAndNotifications)
            )
        }
        #expect(!CompanionPanelSettingsOwnership.owns(
            .notifications,
            on: .overlayAndNotifications,
            presentation: .embeddedOverlayControls
        ))
        #expect(CompanionPanelSettingsOwnership.owns(
            .notifications,
            on: .overlayAndNotifications,
            presentation: .navigation
        ))
        #expect(CompanionPanelSettingsOwnership.draftOwners(for: .voice) == [.voice])
        #expect(CompanionPanelSettingsOwnership.draftOwners(for: .oauth) == [.oauth])
        #expect(CompanionPanelSettingsOwnership.draftOwners(for: .mainAgent) == [.mainAgent])
        #expect(CompanionPanelSettingsOwnership.draftOwners(for: .pickle) == [.pickle])
    }

    @Test func newerVoiceEditIsNotOverwrittenByAnEarlierSaveCompletion() {
        #expect(CompanionVoiceDraftSyncPolicy.shouldSynchronize(
            completedRevision: 4,
            currentRevision: 4
        ))
        #expect(!CompanionVoiceDraftSyncPolicy.shouldSynchronize(
            completedRevision: 4,
            currentRevision: 5
        ))
    }

    @Test func failedOnboardingReplayRestoresVersionBeforeLaterSettingsSave() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-hub-onboarding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let store = PickySettingsStore(appSupportRoot: root)
        var original = PickySettings.defaults(appSupportRoot: root)
        original.defaultCwd = project.path
        original.mainAgentCwd = project.path
        original.worktreeParent = project.path
        original.onboardingCompletedVersion = 7
        try store.save(original)

        let persistence = PickySettingsPersistenceCoordinator(store: store)
        let viewModel = PickySettingsViewModel(store: store, persistence: persistence)
        let replay = PickyHubOnboardingReplaySaveTransaction.begin(in: &viewModel.settings)
        #expect(viewModel.settings.onboardingCompletedVersion == 0)

        try Data("invalid settings".utf8).write(to: store.url, options: .atomic)
        #expect(!(await viewModel.saveDurably()))

        replay.restoreAfterFailedSave(in: &viewModel.settings)
        #expect(viewModel.settings.onboardingCompletedVersion == 7)

        try store.save(original)
        viewModel.settings.appearance = .light
        #expect(await viewModel.saveDurably())
        let saved = try store.loadStrict()
        #expect(saved.onboardingCompletedVersion == 7)
        #expect(saved.appearance == .light)
    }

    @Test func acceptedReplayCannotAppearCancelledWhileItsQueuedWriteCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-replay-busy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        var original = PickySettings.defaults(appSupportRoot: root)
        original.defaultCwd = root.path
        original.mainAgentCwd = root.path
        original.worktreeParent = root.path
        original.onboardingCompletedVersion = 7
        try store.save(original)
        let viewModel = PickySettingsViewModel(store: store)
        _ = PickyHubOnboardingReplaySaveTransaction.begin(in: &viewModel.settings)
        let host = PickyHubModalHost()
        var saving = true
        let id = host.present(accessibilityLabel: "Replay", canDismiss: { !saving }) { EmptyView() }
        let save = Task { await viewModel.saveDurably() }
        host.dismiss()
        #expect(host.presentationID == id)
        #expect(await save.value)
        #expect(try store.loadStrict().onboardingCompletedVersion == 0)
        saving = false
        host.dismiss()
        #expect(host.presentationID == nil)
    }

    @Test func failedOnboardingReplayDoesNotReplaceANewerVersion() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.onboardingCompletedVersion = 7
        let replay = PickyHubOnboardingReplaySaveTransaction.begin(in: &settings)
        settings.onboardingCompletedVersion = 8

        replay.restoreAfterFailedSave(in: &settings)

        #expect(settings.onboardingCompletedVersion == 8)
    }
}
