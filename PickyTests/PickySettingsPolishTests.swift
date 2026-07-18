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

        statuses.markSaved(.overlayAndNotifications)

        #expect(statuses[.overlayAndNotifications] == .saved)
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

    @Test func settingsLoadDefaultsAttachScreenshotsOnlyWhenInkedToFalseWhenLegacyFileLacksField() throws {
        // Existing installs that predate the ink-only screenshot toggle must
        // keep the always-attach behavior so users don't suddenly stop seeing
        // screen context after an update.
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

        #expect(settings.attachScreenshotsOnlyWhenInked == false)
    }

    @Test func settingsLoadDefaultsReportOutlineVisibilityToClosedWhenLegacyFileLacksField() throws {
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

        #expect(settings.reportViewerOutlinePresented == false)
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
        settings.mainAgentThinkingLevel = .max

        try store.save(settings)

        #expect(store.load().mainAgentThinkingLevel == .max)
    }

    @Test func restartRequirementDetectsEffectivePiCodingAgentDirChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-restart-requirement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalAgentDir = root.appendingPathComponent("agent-a", isDirectory: true)
        let newAgentDir = root.appendingPathComponent("agent-b", isDirectory: true)
        try FileManager.default.createDirectory(at: originalAgentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newAgentDir, withIntermediateDirectories: true)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.piCodingAgentDir = originalAgentDir.path
        let applied = PickyRestartRequirementDetector.snapshot(
            from: settings,
            environment: [:],
            homeURL: root
        )

        settings.piCodingAgentDir = newAgentDir.path
        let requirement = PickyRestartRequirementDetector.requirement(
            for: settings,
            applied: applied,
            environment: [:],
            homeURL: root
        )

        #expect(requirement.reasons == [.piCodingAgentDir(desiredPath: newAgentDir.path, appliedPath: originalAgentDir.path)])
    }

    @Test func relauncherShellQuotesBundlePaths() {
        #expect(PickyRelauncher.shellQuoted("/Applications/Picky.app") == "'/Applications/Picky.app'")
        #expect(PickyRelauncher.shellQuoted("/tmp/Picky's App.app") == "'/tmp/Picky'\\''s App.app'")
    }

    @Test func restartRequirementIgnoresPiBinaryPathChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-restart-requirement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var settings = PickySettings.defaults(appSupportRoot: root)
        let applied = PickyRestartRequirementDetector.snapshot(
            from: settings,
            environment: [:],
            homeURL: root
        )

        settings.piBinaryPath = root.appendingPathComponent("custom-pi", isDirectory: false).path
        let requirement = PickyRestartRequirementDetector.requirement(
            for: settings,
            applied: applied,
            environment: [:],
            homeURL: root
        )

        #expect(requirement == .none)
    }

    @MainActor @Test func settingsViewModelSavePreservesRuntimeRecentPickleFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let pinnedProject = root.appendingPathComponent("pinned-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinnedProject, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.mainAgentCwd = project.path
        settings.worktreeParent = project.path
        try store.save(settings)

        let viewModel = PickySettingsViewModel(store: store)
        var runtimeSettings = store.load()
        runtimeSettings.recordRecentPickleCwd(project.path)
        runtimeSettings.pinPickleCwd(pinnedProject.path)
        try store.save(runtimeSettings)

        viewModel.settings.mainAgentThinkingLevel = .high
        #expect(viewModel.save())

        let saved = store.load()
        #expect(saved.mainAgentThinkingLevel == .high)
        #expect(saved.recentPickleCwds == [project.path])
        #expect(saved.pinnedPickleCwds == [pinnedProject.path])
    }

    @MainActor @Test func settingsViewModelSavePreservesFooterControlledPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.mainAgentCwd = project.path
        settings.worktreeParent = project.path
        try store.save(settings)

        let viewModel = PickySettingsViewModel(store: store)
        let appearanceStore = PickyAppearanceStore(settingsStore: store)
        let visibilityStore = PickyHUDVisibilityStore(settingsStore: store)
        appearanceStore.setMode(.light)
        visibilityStore.setVisible(false)

        viewModel.settings.mainAgentThinkingLevel = .high
        #expect(viewModel.save())

        let saved = store.load()
        #expect(saved.mainAgentThinkingLevel == .high)
        #expect(saved.appearance == .light)
        #expect(!saved.hudDockVisible)
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

    @Test func settingsLoadDefaultsArmedPickleDispatchModeToFollowUpWhenLegacyFileLacksField() throws {
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

        #expect(settings.armedPickleDispatchMode == .followUp)
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

    @Test func settingsLoadDefaultsHUDDockVisibleToTrueWhenLegacyFileLacksField() throws {
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.hudDockVisible)
    }

    @MainActor @Test func hudVisibilityStoreTogglesAndPersistsThroughSettingsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let settingsStore = PickySettingsStore(appSupportRoot: root)
        var seed = PickySettings.defaults(appSupportRoot: root)
        seed.defaultCwd = project.path
        seed.mainAgentCwd = project.path
        seed.worktreeParent = project.path
        try settingsStore.save(seed)

        let visibility = PickyHUDVisibilityStore(settingsStore: settingsStore)
        #expect(visibility.isVisible)

        visibility.toggle()
        #expect(!visibility.isVisible)
        #expect(!settingsStore.load().hudDockVisible)

        let rehydrated = PickyHUDVisibilityStore(settingsStore: settingsStore)
        #expect(!rehydrated.isVisible)
    }

    @Test func settingsLoadIgnoresRemovedHUDDockMinimizedField() throws {
        let settingsFromMinimizeCapableBuild = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs",
          "hudDockMinimized": {"1": true}
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: settingsFromMinimizeCapableBuild)
        let reencoded = try JSONEncoder().encode(settings)
        let object = try JSONSerialization.jsonObject(with: reencoded)
        let dictionary = try #require(object as? [String: Any])

        #expect(settings.defaultCwd == "/tmp")
        #expect(dictionary["hudDockMinimized"] == nil)
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

    @Test func settingsRoundTripPreservesArmedPickleDispatchMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.armedPickleDispatchMode = .steer

        try store.save(settings)

        #expect(store.load().armedPickleDispatchMode == .steer)
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
        settings.fontScales = PickyFontScales(markdownReport: 1.4, terminal: 1.8, app: 1.2)
        try store.save(settings)

        let reloaded = store.load().fontScales
        #expect(reloaded.markdownReport == 1.4)
        #expect(reloaded.terminal == 1.8)
        #expect(reloaded.app == 1.2)

        // Out-of-range values stored by an older or corrupted client get clamped on load
        // so the UI never starts in a 0.1× or 10× broken state.
        let url = root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        func overwriteStoredFontScale(_ key: String, with value: Double) throws {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            var json = try #require(object as? [String: Any])
            var scales = try #require(json["fontScales"] as? [String: Any])
            scales[key] = value
            json["fontScales"] = scales
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }

        try overwriteStoredFontScale("markdownReport", with: 99)
        let clamped = store.load().fontScales
        #expect(clamped.markdownReport == PickyFontScales.maximum)
        #expect(clamped.terminal == 1.8)
        #expect(clamped.app == 1.2)

        // Out-of-range app scale clamps to the narrower 0.9...1.3 band.
        try overwriteStoredFontScale("app", with: 5.0)
        let clampedApp = store.load().fontScales.app
        #expect(clampedApp == PickyFontScales.appMaximum)
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
    {"id":"event-\(id)-\(status)","protocolVersion":"2026-07-17","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionUpdated","session":{"id":"\(id)","title":"\(title)","status":"\(status)","cwd":"/tmp/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"\(summary)","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
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
