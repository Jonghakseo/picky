//
//  PickyNotificationPreferencesTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyNotificationPreferences")
struct PickyNotificationPreferencesTests {
    @Test func defaultsLeaveNewPickleCompletionChannelsOffAndOthersOn() {
        let defaults = PickyNotificationPreferences.defaults
        #expect(defaults.notifyMainOnCompletionForNewPickles == false)
        #expect(defaults.notifyMacOSOnCompletionForNewPickles == false)
        #expect(defaults.notifyOnFailed == true)
        #expect(defaults.notifyOnWaitingForInput == true)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = PickyNotificationPreferences(
            notifyMainOnCompletionForNewPickles: true,
            notifyMacOSOnCompletionForNewPickles: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: false
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(PickyNotificationPreferences.self, from: data)

        #expect(restored == original)
    }

    @Test func legacySettingsWithoutNotificationsKeyDecodeUsingDefaults() throws {
        let legacyJSON = """
        {
            "appearance": "dark",
            "azureSTTPreferredLanguage": "",
            "daemonPath": "bundled picky-agentd or local development agentd",
            "defaultCwd": "/tmp",
            "followsFocusedScreen": true,
            "logPath": "/tmp/Logs",
            "preferredToolVisibility": "visible in context only",
            "readOnlyInvestigationPreference": true,
            "sttProvider": "automatic",
            "ttsProvider": "automatic",
            "worktreeParent": "/tmp"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.notifications == .defaults)
    }

    @Test func migratesReleasedMacOSCompletionToggleToFuturePickleDefaultOnly() throws {
        let decoder = JSONDecoder()
        let legacyOn = try decoder.decode(PickyNotificationPreferences.self, from: Data(#"{"notifyOnCompleted":true,"notifyOnFailed":false,"notifyOnWaitingForInput":true}"#.utf8))
        let legacyOff = try decoder.decode(PickyNotificationPreferences.self, from: Data(#"{"notifyOnCompleted":false,"notifyOnFailed":true,"notifyOnWaitingForInput":false}"#.utf8))
        let missing = try decoder.decode(PickyNotificationPreferences.self, from: Data(#"{"notifyOnFailed":true,"notifyOnWaitingForInput":true}"#.utf8))

        #expect(legacyOn.notifyMainOnCompletionForNewPickles == false)
        #expect(legacyOn.notifyMacOSOnCompletionForNewPickles == true)
        #expect(legacyOff.notifyMacOSOnCompletionForNewPickles == false)
        #expect(missing.notifyMainOnCompletionForNewPickles == false)
        #expect(missing.notifyMacOSOnCompletionForNewPickles == false)
        #expect(legacyOn.notifyOnFailed == false)
        #expect(legacyOff.notifyOnWaitingForInput == false)
    }

    @Test func migratesUnreleasedDestinationAndMasterToTwoFutureDefaults() throws {
        let decoder = JSONDecoder()
        let both = try decoder.decode(PickyNotificationPreferences.self, from: Data(#"{"completionDestination":"both","notifyOnCompletionForNewPickles":true}"#.utf8))
        let disabled = try decoder.decode(PickyNotificationPreferences.self, from: Data(#"{"completionDestination":"both","notifyOnCompletionForNewPickles":false}"#.utf8))
        let missingDestination = try decoder.decode(PickyNotificationPreferences.self, from: Data(#"{"notifyOnCompletionForNewPickles":true}"#.utf8))
        let unknownDestination = try decoder.decode(PickyNotificationPreferences.self, from: Data(#"{"completionDestination":"future","notifyOnCompletionForNewPickles":true}"#.utf8))

        #expect(both.notifyMainOnCompletionForNewPickles)
        #expect(both.notifyMacOSOnCompletionForNewPickles)
        #expect(disabled.notifyMainOnCompletionForNewPickles == false)
        #expect(disabled.notifyMacOSOnCompletionForNewPickles == false)
        #expect(missingDestination.notifyMainOnCompletionForNewPickles)
        #expect(missingDestination.notifyMacOSOnCompletionForNewPickles == false)
        #expect(unknownDestination.notifyMainOnCompletionForNewPickles)
        #expect(unknownDestination.notifyMacOSOnCompletionForNewPickles == false)
    }

    @Test func newSettingsWithToggleStateRoundTripThroughDisk() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let store = PickySettingsStore(url: temp.appendingPathComponent("settings.json"))

        var settings = PickySettings.defaults(appSupportRoot: temp)
        settings.defaultCwd = cwd
        settings.worktreeParent = cwd
        settings.notifications = PickyNotificationPreferences(
            notifyMainOnCompletionForNewPickles: true,
            notifyMacOSOnCompletionForNewPickles: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: false
        )
        try store.save(settings)

        let reloaded = store.load()
        #expect(reloaded.notifications.notifyMainOnCompletionForNewPickles == true)
        #expect(reloaded.notifications.notifyMacOSOnCompletionForNewPickles == true)
        #expect(reloaded.notifications.notifyOnFailed == true)
        #expect(reloaded.notifications.notifyOnWaitingForInput == false)
    }
}

@Suite("PickyNotificationPreferencesStore")
struct PickyNotificationPreferencesStoreTests {
    @Test func loadsCurrentSettingsOnInit() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let settingsStore = PickySettingsStore(url: temp.appendingPathComponent("settings.json"))

        var settings = PickySettings.defaults(appSupportRoot: temp)
        settings.defaultCwd = cwd
        settings.worktreeParent = cwd
        settings.notifications = PickyNotificationPreferences(
            notifyMainOnCompletionForNewPickles: false,
            notifyMacOSOnCompletionForNewPickles: false,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        )
        try settingsStore.save(settings)

        let store = PickyNotificationPreferencesStore(settingsStore: settingsStore)
        #expect(store.notificationPreferences.notifyMacOSOnCompletionForNewPickles == false)
    }

    @Test func refreshesAfterPickySettingsDidSavePost() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let settingsStore = PickySettingsStore(url: temp.appendingPathComponent("settings.json"))

        var settings = PickySettings.defaults(appSupportRoot: temp)
        settings.defaultCwd = cwd
        settings.worktreeParent = cwd
        settings.notifications = PickyNotificationPreferences(
            notifyMainOnCompletionForNewPickles: false,
            notifyMacOSOnCompletionForNewPickles: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        )
        try settingsStore.save(settings)

        let store = PickyNotificationPreferencesStore(settingsStore: settingsStore)
        #expect(store.notificationPreferences.notifyMacOSOnCompletionForNewPickles == true)

        settings.notifications.notifyMacOSOnCompletionForNewPickles = false
        try settingsStore.save(settings)
        await MainActor.run {
            NotificationCenter.default.post(name: .pickySettingsDidSave, object: nil)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.notificationPreferences.notifyMacOSOnCompletionForNewPickles == false)
    }
}

@Suite("PickyStubNotificationPreferences")
struct PickyStubNotificationPreferencesTests {
    @Test func defaultsToAllChannelsOn() {
        let stub = PickyStubNotificationPreferences()
        #expect(stub.notificationPreferences == .defaults)
    }

    @Test func mutationFlipsObservedValue() {
        let stub = PickyStubNotificationPreferences()
        stub.notificationPreferences.notifyOnFailed = false
        #expect(stub.notificationPreferences.notifyOnFailed == false)
        #expect(stub.notificationPreferences.notifyMacOSOnCompletionForNewPickles == PickyNotificationPreferences.defaults.notifyMacOSOnCompletionForNewPickles)
    }
}
