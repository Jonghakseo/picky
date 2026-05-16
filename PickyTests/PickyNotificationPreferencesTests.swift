//
//  PickyNotificationPreferencesTests.swift
//  PickyTests
//
//  Unit tests for the notification toggle plumbing introduced alongside the
//  Settings-tab "Notifications" section. End-to-end coverage of how
//  `PickySessionListViewModel` consults these toggles lives in
//  `PickySessionViewModelTests.swift`; this file only exercises the
//  preference value type, the JSON migration, and the settings-store
//  observer wired into `PickyNotificationPreferencesStore`.
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyNotificationPreferences")
struct PickyNotificationPreferencesTests {
    @Test func defaultsLeaveCompletedOffAndOthersOn() {
        let defaults = PickyNotificationPreferences.defaults
        #expect(defaults.notifyOnCompleted == false)
        #expect(defaults.notifyOnFailed == true)
        #expect(defaults.notifyOnWaitingForInput == true)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = PickyNotificationPreferences(
            notifyOnCompleted: false,
            notifyOnFailed: true,
            notifyOnWaitingForInput: false
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(PickyNotificationPreferences.self, from: data)

        #expect(restored == original)
    }

    @Test func legacySettingsWithoutNotificationsKeyDecodeUsingDefaults() throws {
        // settings.json files written before the toggles shipped do not contain a
        // `notifications` key. Decoding must fall back to the all-on defaults so
        // existing users keep seeing the same banners they had before.
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
            notifyOnCompleted: false,
            notifyOnFailed: true,
            notifyOnWaitingForInput: false
        )
        try store.save(settings)

        let reloaded = store.load()
        #expect(reloaded.notifications.notifyOnCompleted == false)
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
            notifyOnCompleted: false,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        )
        try settingsStore.save(settings)

        let store = PickyNotificationPreferencesStore(settingsStore: settingsStore)
        #expect(store.notificationPreferences.notifyOnCompleted == false)
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
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        )
        try settingsStore.save(settings)

        let store = PickyNotificationPreferencesStore(settingsStore: settingsStore)
        #expect(store.notificationPreferences.notifyOnCompleted == true)

        settings.notifications.notifyOnCompleted = false
        try settingsStore.save(settings)
        await MainActor.run {
            NotificationCenter.default.post(name: .pickySettingsDidSave, object: nil)
        }
        // The observer is registered on the main queue; settle before reading back.
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.notificationPreferences.notifyOnCompleted == false)
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
        #expect(stub.notificationPreferences.notifyOnCompleted == PickyNotificationPreferences.defaults.notifyOnCompleted)
    }
}
