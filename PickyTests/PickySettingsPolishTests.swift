//
//  PickySettingsPolishTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickySettingsPolishTests {
    @Test func companionSettingsSaveStatusIsSectionScoped() {
        var statuses = CompanionPanelSettingsSaveStatuses()

        statuses.markSaved(.notification)

        #expect(statuses[.notification] == .saved)
        #expect(statuses[.pickle] == .idle)
        #expect(statuses[.voice] == .idle)
    }

    @Test func companionSettingsSaveStatusResetDoesNotTouchOtherSections() {
        var statuses = CompanionPanelSettingsSaveStatuses()
        statuses.markDirty(.pickle)
        statuses.markSaved(.voice)

        statuses.clearSaved(.voice)

        #expect(statuses[.pickle] == .dirty)
        #expect(statuses[.voice] == .idle)
    }

    @Test func settingsLoadDefaultsMainAgentThinkingLevelToOffWhenLegacyFileLacksField() throws {
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.mainAgentThinkingLevel == .off)
    }

    @Test func updateChannelDefaultsFollowBuildReleaseChannel() {
        #expect(PickySettings.defaultUpdateChannel(forReleaseChannel: "beta") == .beta)
        #expect(PickySettings.defaultUpdateChannel(forReleaseChannel: " Beta ") == .beta)
        #expect(PickySettings.defaultUpdateChannel(forReleaseChannel: "stable") == .stable)
        #expect(PickySettings.defaultUpdateChannel(forReleaseChannel: "alpha") == .stable)
        #expect(PickySettings.defaultUpdateChannel(forReleaseChannel: "") == .stable)
    }

    @Test func sparkleAllowedChannelsFollowBuildReleaseChannel() {
        #expect(PickyUpdaterController.allowedChannels(forReleaseChannel: "stable") == ["stable"])
        #expect(PickyUpdaterController.allowedChannels(forReleaseChannel: " Stable ") == ["stable"])
        #expect(PickyUpdaterController.allowedChannels(forReleaseChannel: "beta") == ["beta"])
        #expect(PickyUpdaterController.allowedChannels(forReleaseChannel: "alpha").isEmpty)
    }

    @Test func settingsNoLongerPersistPerPickleRuntimeAndIgnoreLegacyField() throws {
        let defaults = PickySettings.defaults()
        let encoded = try JSONEncoder().encode(defaults)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("perPickleRuntime"))

        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs",
          "perPickleRuntime": false
        }
        """.data(using: .utf8)!

        _ = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)
    }

    @Test func settingsRoundTripPreservesMainAgentThinkingLevel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.mainAgentThinkingLevel = .high

        try store.save(settings)

        #expect(store.load().mainAgentThinkingLevel == .high)
    }

    @Test func settingsLoadDefaultsMainAgentRuntimeToPiWhenLegacyFileLacksField() throws {
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.mainAgentRuntimeMode == .pi)
        #expect(settings.openAIRealtime.modelOrDeployment == "gpt-realtime-2")
        #expect(settings.openAIRealtime.provider == .openAI)
        #expect(settings.openAIRealtime.azureRealtimeURL.isEmpty)
    }

    @Test func effectiveRuntimeModeUsesLaunchSnapshotUntilCacheReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.mainAgentCwd = project.path
        settings.worktreeParent = project.path
        settings.mainAgentRuntimeMode = .pi
        settings.mainAgentRuntimeModeRealtimeOptInMigrationApplied = true
        try store.save(settings)

        AppBundleConfiguration.resetEffectiveRuntimeModeCacheForTesting()
        defer { AppBundleConfiguration.resetEffectiveRuntimeModeCacheForTesting() }

        try AppBundleConfiguration.$testRuntimeModeSettingsURL.withValue(store.url) {
            #expect(AppBundleConfiguration.effectiveRuntimeMode == .pi)

            var updated = settings
            updated.mainAgentRuntimeMode = .openAIRealtime
            try store.save(updated)

            #expect(AppBundleConfiguration.effectiveRuntimeMode == .pi)

            AppBundleConfiguration.resetEffectiveRuntimeModeCacheForTesting()
            #expect(AppBundleConfiguration.effectiveRuntimeMode == .openAIRealtime)
        }
    }

    @Test func runtimeModeTestOverrideStillWinsOverLaunchSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.mainAgentCwd = project.path
        settings.worktreeParent = project.path
        settings.mainAgentRuntimeMode = .pi
        settings.mainAgentRuntimeModeRealtimeOptInMigrationApplied = true
        try store.save(settings)

        AppBundleConfiguration.resetEffectiveRuntimeModeCacheForTesting()
        defer { AppBundleConfiguration.resetEffectiveRuntimeModeCacheForTesting() }

        try AppBundleConfiguration.$testRuntimeModeSettingsURL.withValue(store.url) {
            #expect(AppBundleConfiguration.effectiveRuntimeMode == .pi)
            try AppBundleConfiguration.$testRuntimeModeOverride.withValue(.openAIRealtime) {
                #expect(AppBundleConfiguration.effectiveRuntimeMode == .openAIRealtime)
            }
            #expect(AppBundleConfiguration.effectiveRuntimeMode == .pi)
        }
    }

    @Test func realtimeOptInBuildMigratesRuntimeModeOnceAndPersistsMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.mainAgentCwd = project.path
        settings.worktreeParent = project.path
        settings.mainAgentRuntimeMode = .pi
        settings.mainAgentRuntimeModeRealtimeOptInMigrationApplied = false
        try store.save(settings)

        let loaded = AppBundleConfiguration.$testRealtimeOptInOverride.withValue(true) {
            store.load()
        }

        #expect(loaded.mainAgentRuntimeMode == .openAIRealtime)
        #expect(loaded.mainAgentRuntimeModeRealtimeOptInMigrationApplied)
        let persisted = try JSONDecoder().decode(PickySettings.self, from: Data(contentsOf: store.url))
        #expect(persisted.mainAgentRuntimeMode == .openAIRealtime)
        #expect(persisted.mainAgentRuntimeModeRealtimeOptInMigrationApplied)
    }

    @Test func realtimeOptInMigrationMarkerPreservesLaterPiSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.mainAgentCwd = project.path
        settings.worktreeParent = project.path
        settings.mainAgentRuntimeMode = .pi
        settings.mainAgentRuntimeModeRealtimeOptInMigrationApplied = true
        try store.save(settings)

        let loaded = AppBundleConfiguration.$testRealtimeOptInOverride.withValue(true) {
            store.load()
        }

        #expect(loaded.mainAgentRuntimeMode == .pi)
        #expect(loaded.mainAgentRuntimeModeRealtimeOptInMigrationApplied)
    }

    @Test func realtimeOptInFreshInstallDefaultsToRealtimeRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)

        let loaded = AppBundleConfiguration.$testRealtimeOptInOverride.withValue(true) {
            store.load()
        }

        #expect(loaded.mainAgentRuntimeMode == .openAIRealtime)
        #expect(loaded.mainAgentRuntimeModeRealtimeOptInMigrationApplied)
    }

    @Test func nonRealtimeOptInFreshInstallDefaultsToPiRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)

        let loaded = AppBundleConfiguration.$testRealtimeOptInOverride.withValue(false) {
            store.load()
        }

        #expect(loaded.mainAgentRuntimeMode == .pi)
        #expect(!loaded.mainAgentRuntimeModeRealtimeOptInMigrationApplied)
    }

    @Test func settingsRoundTripPreservesOpenAIRealtimeSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.mainAgentRuntimeMode = .openAIRealtime
        settings.openAIRealtime = PickyOpenAIRealtimeSettings(
            provider: .azureOpenAI,
            apiKey: " azure-key ",
            modelOrDeployment: " realtime-deployment ",
            azureRealtimeURL: " https://resource.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5 ",
            azureResourceEndpoint: " https://resource.openai.azure.com ",
            azureAPIVersion: " 2025-04-01-preview ",
            azureAPIShape: .preview,
            voice: " marin ",
            reasoningEffort: .high,
            transcriptionLanguage: " ko "
        )

        try store.save(settings)
        let loaded = store.load()

        #expect(loaded.mainAgentRuntimeMode == .openAIRealtime)
        #expect(loaded.openAIRealtime.provider == .azureOpenAI)
        #expect(loaded.openAIRealtime.apiKey == "azure-key")
        #expect(loaded.openAIRealtime.modelOrDeployment == "realtime-deployment")
        #expect(loaded.openAIRealtime.azureRealtimeURL == "https://resource.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5")
        #expect(loaded.openAIRealtime.azureResourceEndpoint == "https://resource.openai.azure.com")
        #expect(loaded.openAIRealtime.azureAPIVersion == "2025-04-01-preview")
        #expect(loaded.openAIRealtime.azureAPIShape == .preview)
        #expect(loaded.openAIRealtime.voice == "marin")
        #expect(loaded.openAIRealtime.reasoningEffort == .high)
        #expect(loaded.openAIRealtime.transcriptionLanguage == "ko")
    }

    @Test func azureRealtimeURLParserDerivesPreviewProtocolFields() throws {
        let parsed = try #require(PickyAzureOpenAIRealtimeURLComponents.parse("https://example-openai.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5"))

        #expect(parsed.resourceEndpoint == "https://example-openai.openai.azure.com")
        #expect(parsed.deployment == "gpt-realtime-1.5")
        #expect(parsed.apiVersion == "2024-10-01-preview")
        #expect(parsed.apiShape == .preview)
    }

    @Test func legacyAzureRealtimeSettingsSynthesizeFullURL() throws {
        let legacyJSON = """
        {
          "provider": "azureOpenAI",
          "apiKey": "key",
          "modelOrDeployment": "deployment-one",
          "azureResourceEndpoint": "https://resource.openai.azure.com",
          "azureAPIVersion": "2024-10-01-preview",
          "azureAPIShape": "preview",
          "voice": "marin",
          "reasoningEffort": "medium",
          "transcriptionLanguage": ""
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickyOpenAIRealtimeSettings.self, from: legacyJSON).normalized()

        #expect(settings.azureRealtimeURL == "https://resource.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=deployment-one")
    }

    @Test func settingsLoadDefaultsScreenContextScopeToFocusedScreenWhenLegacyFileLacksField() throws {
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.screenContextScope == .focusedScreen)
    }

    @Test func settingsLoadDefaultsScreenshotQualityToOnePointFiveWhenLegacyFileLacksField() throws {
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.screenshotQuality == .onePointFive)
        #expect(settings.screenshotQuality.maximumDimension == 1920)
    }

    @Test func settingsLoadDefaultsOverlayBubblesToVisibleWhenLegacyFileLacksField() throws {
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.overlayBubbles.showUserSpeechRecognitionBubble)
        #expect(settings.overlayBubbles.showPickyResponseBubble)
    }

    @Test func settingsLoadDefaultsCursorFollowSpringToEnabledWhenLegacyFileLacksField() throws {
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.cursor.enableFollowSpringAnimation)
    }

    @Test func settingsLoadDefaultsHUDDockSizePresetToMediumWhenLegacyFileLacksField() throws {
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.hudDockSizePreset == .medium)
    }

    @Test func settingsRoundTripPreservesHUDDockSizePreset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.hudDockSizePreset = .large

        try store.save(settings)

        #expect(store.load().hudDockSizePreset == .large)
    }

    @Test func settingsRoundTripPreservesHUDCardSizes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.hudCardSizes = ["display-a": PickyHUDCardSize(width: 520, height: 440)]

        try store.save(settings)

        #expect(store.load().hudCardSizes["display-a"] == PickyHUDCardSize(width: 520, height: 440))
    }

    @Test func settingsRoundTripClampsHUDCardSizes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.hudCardSizes = ["display-a": PickyHUDCardSize(width: 99_999, height: 99_999)]

        try store.save(settings)

        #expect(store.load().hudCardSizes["display-a"] == PickyHUDCardSize(width: 10_000, height: 10_000))
    }

    @Test func settingsRoundTripPreservesOverlayBubblePreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.overlayBubbles = PickyOverlayBubblePreferences(
            showUserSpeechRecognitionBubble: false,
            showPickyResponseBubble: true
        )

        try store.save(settings)

        #expect(store.load().overlayBubbles.showUserSpeechRecognitionBubble == false)
        #expect(store.load().overlayBubbles.showPickyResponseBubble == true)
    }

    @Test func settingsRoundTripPreservesCursorFollowSpringPreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.cursor.enableFollowSpringAnimation = false

        try store.save(settings)

        #expect(store.load().cursor.enableFollowSpringAnimation == false)
    }

    @Test func cursorTrackingRefreshesAt60FPS() {
        #expect(BlueCursorView.cursorTrackingInterval == 1.0 / 60.0)
    }

    @Test func cursorShakeReactionRequiresIntentionalMovementIntensity() {
        #expect(BlueCursorView.shakeReactionRequiredDuration == 2.0)
        #expect(BlueCursorView.shakeReactionMinimumSpeed == 720)
        #expect(BlueCursorView.shakeReactionMinimumDominantDelta == 5.5)
        #expect(BlueCursorView.shakeReactionRequiredDirectionChanges == 8)
    }

    @Test func settingsRoundTripPreservesScreenContextScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.screenContextScope = .focusedScreen

        try store.save(settings)

        #expect(store.load().screenContextScope == .focusedScreen)
    }

    @Test func settingsRoundTripPreservesScreenshotQuality() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.screenshotQuality = .double

        try store.save(settings)

        #expect(store.load().screenshotQuality == .double)
        #expect(store.load().screenshotQuality.maximumDimension == 2560)
    }

    @Test func settingsLoadDefaultsAppearanceToDarkWhenLegacyFileLacksField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Settings", isDirectory: true), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: url)
        let store = PickySettingsStore(url: url)

        #expect(store.load().appearance == .dark)
    }

    @Test func fontScalesClampingRoundsAndBoundsValuesIntoTheSupportedRange() throws {
        #expect(PickyFontScales.clamped(1.0) == 1.0)
        #expect(PickyFontScales.clamped(0.0) == PickyFontScales.minimum)
        #expect(PickyFontScales.clamped(99) == PickyFontScales.maximum)
        // 0.1 step taps should accumulate exactly because clamped() rounds to one decimal.
        var value = 1.0
        for _ in 0..<3 { value = PickyFontScales.clamped(value + 0.1) }
        #expect(value == 1.3)
    }

    @Test func settingsLoadDefaultsFontScalesToOneWhenLegacyFileLacksField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Settings", isDirectory: true), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: url)
        let store = PickySettingsStore(url: url)

        let loaded = store.load().fontScales
        #expect(loaded.markdownReport == 1.0)
        #expect(loaded.terminal == 1.0)
    }

    @Test func settingsRoundTripPreservesAndClampsFontScales() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.fontScales = PickyFontScales(markdownReport: 1.4, terminal: 1.8)
        try store.save(settings)

        let reloaded = store.load().fontScales
        #expect(reloaded.markdownReport == 1.4)
        #expect(reloaded.terminal == 1.8)

        // Out-of-range values stored by an older or corrupted client get clamped on load
        // so the UI never starts in a 0.1× or 10× broken state.
        let url = root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        let raw = try String(contentsOf: url)
        let mutated = raw.replacingOccurrences(of: "\"markdownReport\" : 1.4", with: "\"markdownReport\" : 99")
        try mutated.data(using: .utf8)!.write(to: url)
        let clamped = store.load().fontScales
        #expect(clamped.markdownReport == PickyFontScales.maximum)
        #expect(clamped.terminal == 1.8)
    }

    @Test func settingsRoundTripPreservesOnboardingCompletedVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        // Fresh install path: defaults() seeds zero, the reset button restores zero, and
        // markOnboardingComplete writes the current build's revision. Round-trip each.
        #expect(settings.onboardingCompletedVersion == 0)
        settings.onboardingCompletedVersion = PickyOnboardingVersion.current
        try store.save(settings)
        #expect(store.load().onboardingCompletedVersion == PickyOnboardingVersion.current)

        settings.onboardingCompletedVersion = 0
        try store.save(settings)
        #expect(store.load().onboardingCompletedVersion == 0)
    }

    @Test func settingsRoundTripPreservesShellCommandAutoInstallOptOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        // Fresh installs start opted-in so the launch-time auto-installer gets
        // one chance to drop the wrapper.
        #expect(settings.shellCommandAutoInstallOptedOut == false)
        settings.shellCommandAutoInstallOptedOut = true
        try store.save(settings)
        #expect(store.load().shellCommandAutoInstallOptedOut == true)

        settings.shellCommandAutoInstallOptedOut = false
        try store.save(settings)
        #expect(store.load().shellCommandAutoInstallOptedOut == false)
    }

    @Test func settingsDecodeTreatsLegacyFileAsAutoInstallOptedIn() throws {
        // Settings files written before the auto-installer existed have no
        // `shellCommandAutoInstallOptedOut` key. They should decode as
        // opted-in (false) so existing users get the same silent install
        // behavior as fresh installs.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Settings", isDirectory: true), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: url)
        let store = PickySettingsStore(url: url)

        #expect(store.load().shellCommandAutoInstallOptedOut == false)
    }

    @Test func settingsDecodeTreatsLegacyFileAsOnboardingAlreadyCompleted() throws {
        // Pre-onboarding settings files have no `onboardingCompletedVersion` key. Updating
        // users should not get ambushed by the takeover demo, so the decoder treats the
        // missing field as "this install already finished the latest onboarding".
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Settings", isDirectory: true), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: url)
        let store = PickySettingsStore(url: url)

        #expect(store.load().onboardingCompletedVersion == PickyOnboardingVersion.current)
    }

    @Test func settingsRoundTripPreservesAppearanceMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.appearance = .light

        try store.save(settings)
        #expect(store.load().appearance == .light)
    }

    @Test func appearanceStoreToggleAndPersistsThroughSettingsFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let settingsStore = PickySettingsStore(appSupportRoot: root)
        var seed = PickySettings.defaults(appSupportRoot: root)
        seed.defaultCwd = project.path
        seed.worktreeParent = project.path
        try settingsStore.save(seed)

        let appearance = await PickyAppearanceStore(settingsStore: settingsStore)
        await #expect(appearance.mode == .dark)

        await appearance.toggle()
        await #expect(appearance.mode == .light)

        let reloaded = settingsStore.load()
        #expect(reloaded.appearance == .light)

        let rehydrated = await PickyAppearanceStore(settingsStore: settingsStore)
        await #expect(rehydrated.mode == .light)
    }

    @Test func settingsPersistReloadAndRejectInvalidCwd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let worktrees = root.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        let settings = PickySettings(
            defaultCwd: project.path,
            worktreeParent: worktrees.path,
            preferredToolVisibility: "show tool activity",
            readOnlyInvestigationPreference: true,
            daemonPath: "/tmp/agentd",
            logPath: root.appendingPathComponent("Logs").path
        )

        try store.save(settings)
        #expect(store.load() == settings)

        var invalid = settings
        invalid.defaultCwd = root.appendingPathComponent("missing").path
        #expect(throws: PickySettingsValidationError.invalidDefaultCwd(invalid.defaultCwd)) {
            try store.save(invalid)
        }
    }

    @Test func settingsNormalizeTildePathsBeforePersisting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let store = PickySettingsStore(appSupportRoot: root)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let settings = PickySettings(
            defaultCwd: "~",
            worktreeParent: "~",
            preferredToolVisibility: "show tool activity",
            readOnlyInvestigationPreference: true,
            daemonPath: "/tmp/agentd",
            logPath: root.appendingPathComponent("Logs").path
        )

        try store.save(settings)

        #expect(store.load().defaultCwd == home)
        #expect(store.load().worktreeParent == home)
    }

    @Test func diffPreviewGroupsFilesAndTruncatesSafely() {
        let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        +aaaaaa
        diff --git a/Sources/B.swift b/Sources/B.swift
        +bbbbbb
        """

        let preview = PickyDiffPreviewBuilder(maxCharactersPerFile: 20).build(from: diff)

        #expect(preview.files.map(\.path) == ["Sources/A.swift", "Sources/B.swift"])
        #expect(preview.files.allSatisfy { $0.isTruncated })
        #expect(preview.files.first?.text.contains("[diff truncated by Picky]") == true)
    }

    @Test func archiveSearchUsesTitleCwdStatusPrAndSummaryWithoutFabrication() {
        let pr = PickyArtifact(id: "pr-1", kind: "pr", title: "PR", path: nil, url: URL(string: "https://github.com/acme/repo/pull/77")!, updatedAt: Date(timeIntervalSince1970: 1))
        let running = session(id: "running", title: "Investigate checkout", status: .running, cwd: "/tmp/shop", summary: "looking", artifacts: [])
        let completed = session(id: "done", title: "Ship fix", status: .completed, cwd: "/tmp/picky", summary: "final answer", artifacts: [pr])
        var archive = PickySessionArchive(active: [running, completed])

        archive.archive(sessionID: "done")

        #expect(archive.active.map(\.id) == ["running"])
        #expect(archive.archived.map(\.id) == ["done"])
        #expect(archive.search("pull/77").map(\.id) == ["done"])
        #expect(archive.search("running").map(\.id) == ["running"])
        #expect(archive.search("made up verification").isEmpty)
    }

    @MainActor
    @Test func viewModelArchivesAndSearchesSessions() async throws {
        let client = FakePolishClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: sessionUpdatedJSON(id: "archive-me", title: "Archive Me", status: "completed", summary: "final summary"))))
        try await waitUntil {
            (viewModel.sessions + viewModel.archivedSessions).contains(where: { $0.id == "archive-me" })
        }

        viewModel.archive(sessionID: "archive-me")

        #expect(viewModel.sessions.isEmpty)
        #expect(viewModel.archivedSessions.map(\.id) == ["archive-me"])
        #expect(viewModel.searchSessions(query: "final").map(\.id) == ["archive-me"])
    }

    @Test func friendlyMissingPiErrorsAreActionable() {
        let checker = PickyRuntimeDependencyChecker(pathEnvironment: "/tmp", additionalProbePaths: [])

        #expect(checker.missingPiExecutableErrorIfNeeded() == .missingPiExecutable)
        #expect(PickyFriendlyRuntimeError.permissionDenied("Screen Recording").localizedDescription.contains("reduced context"))
    }

    @Test func piExecutableCheckProbesPathThenWellKnownFallbacks() throws {
        // Pi can land in many places (Homebrew, asdf, nvm, ~/.pi/agent/bin…)
        // and macOS apps launched via Launch Services often see a stripped PATH.
        // The checker satisfies as long as `pi` is executable in any inherited
        // PATH directory OR any explicit fallback we probe, mirroring what a
        // shell would resolve via `which pi`.
        let pathOnlyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-pi-path-\(UUID().uuidString)", isDirectory: true)
        let fallbackRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-pi-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pathOnlyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)

        // Pi present only via inherited PATH.
        let inheritedPiPath = pathOnlyRoot.appendingPathComponent("pi").path
        FileManager.default.createFile(atPath: inheritedPiPath, contents: Data(), attributes: [.posixPermissions: 0o755])
        let pathOnly = PickyRuntimeDependencyChecker(pathEnvironment: pathOnlyRoot.path, additionalProbePaths: [])
        #expect(pathOnly.missingPiExecutableErrorIfNeeded() == nil)

        // Pi present only via well-known fallback (simulates the Launch Services
        // case where PATH is reduced to `/usr/bin:/bin:/usr/sbin:/sbin`).
        let fallbackPiPath = fallbackRoot.appendingPathComponent("pi").path
        FileManager.default.createFile(atPath: fallbackPiPath, contents: Data(), attributes: [.posixPermissions: 0o755])
        let fallbackOnly = PickyRuntimeDependencyChecker(pathEnvironment: "/tmp", additionalProbePaths: [fallbackRoot.path])
        #expect(fallbackOnly.missingPiExecutableErrorIfNeeded() == nil)

        // Neither in PATH nor in any fallback -> still missing.
        let neither = PickyRuntimeDependencyChecker(pathEnvironment: "/tmp", additionalProbePaths: ["/no/such/dir"])
        #expect(neither.missingPiExecutableErrorIfNeeded() == .missingPiExecutable)
    }

    @Test func forcePiMissingOverrideMakesEvenAValidInstallReportAsMissing() throws {
        // Simulates `PICKY_FORCE_PI_MISSING=1`. Wire up a real `pi` so the
        // non-forced branch would otherwise return nil, then flip the override.
        let binRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-fake-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: binRoot, withIntermediateDirectories: true)
        let piPath = binRoot.appendingPathComponent("pi").path
        FileManager.default.createFile(atPath: piPath, contents: Data(), attributes: [.posixPermissions: 0o755])

        var checker = PickyRuntimeDependencyChecker(pathEnvironment: binRoot.path, additionalProbePaths: [])
        #expect(checker.missingPiExecutableErrorIfNeeded() == nil)

        checker.forceMissing = true
        #expect(checker.missingPiExecutableErrorIfNeeded() == .missingPiExecutable)
    }

    private func session(id: String, title: String, status: PickySessionStatus, cwd: String, summary: String, artifacts: [PickyArtifact]) -> PickyAgentSession {
        PickyAgentSession(
            id: id,
            title: title,
            status: status,
            cwd: cwd,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            lastSummary: summary,
            logs: [],
            tools: [],
            artifacts: artifacts,
            changedFiles: [],
            pendingExtensionUiRequest: nil
        )
    }
}

private final class FakePolishClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt { PickyAgentSubmissionReceipt(sessionID: "unused", message: "unused") }
    func send(_ command: PickyCommandEnvelope) async throws {}
    func disconnect() { continuation.yield(.disconnected) }
    func emit(_ event: PickyClientEvent) { continuation.yield(event) }
}

private func sessionUpdatedJSON(id: String, title: String, status: String, summary: String) -> String {
    """
    {"id":"event-\(id)-\(status)","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionUpdated","session":{"id":"\(id)","title":"\(title)","status":"\(status)","cwd":"/tmp/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"\(summary)","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
    """
}

private extension PickyEventEnvelope {
    static func fixture(eventJSON: String) -> PickyEventEnvelope {
        try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(eventJSON.utf8))
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("Timed out waiting for condition")
}
