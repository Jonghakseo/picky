//
//  PickyCursorPreferenceTests.swift
//  PickyTests
//
//  Settings → "Show Picky cursor" drives the overlay window lifecycle
//  (single source of truth), including the one-shot migration off the
//  legacy `isPickyCursorEnabled` UserDefaults key.
//

import Foundation
import Testing
@testable import Picky

@MainActor
private final class FakeInkCaptureCoordinator: PickyInkCaptureCoordinating {
    var isActive: Bool = false
    var onStateChange: (PickyInkOverlayState) -> Void = { _ in }
    var shouldPassThroughMouseEvent: (CGPoint, PickyInkCaptureSource) -> Bool = { _, _ in false }

    func begin(source: PickyInkCaptureSource, origin: CGPoint) -> Bool { true }
    func finish(warpSystemCursor: Bool) -> PickyInkCapture? { nil }
    func cancel() {}
}

private final class FakeCursorSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
    var screenContextTargetSticky: Bool = false

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sessionID == nil ? false : sticky
    }
}

@MainActor
struct PickyCursorPreferenceTests {
    private func makeTempStore() -> PickySettingsStore {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyCursorPreferenceTests-\(UUID().uuidString)")
        return PickySettingsStore(url: temp.appendingPathComponent("Settings/settings.json"))
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PickyCursorPreferenceTests-\(UUID().uuidString)")!
    }

    private func settings(showPiCursor: Bool) -> PickySettings {
        var settings = makeTempStore().load()
        settings.cursor.showPiCursor = showPiCursor
        return settings
    }

    private func makeManager(initialSettings: PickySettings, ink: FakeInkCaptureCoordinator) -> CompanionManager {
        CompanionManager(
            selectionStore: FakeCursorSelectionStore(),
            initialSettings: initialSettings,
            inkCaptureCoordinator: ink
        )
    }

    private var activeInkState: PickyInkOverlayState {
        PickyInkOverlayState(
            isActive: true,
            source: .text,
            virtualCursorGlobalPoint: nil,
            strokes: [],
            didCrossThreshold: false,
            thresholdFeedbackGlobalPoint: nil,
            cursorTrailPoints: []
        )
    }

    // MARK: - Legacy key migration

    @Test func migrationFoldsLegacyDisabledFlagIntoSettings() {
        let store = makeTempStore()
        let defaults = makeDefaults()
        defaults.set(false, forKey: "isPickyCursorEnabled")

        let migrated = CompanionManager.migrateLegacyCursorPreferenceIfNeeded(store: store, defaults: defaults)

        #expect(!migrated.cursor.showPiCursor)
        #expect(!store.load().cursor.showPiCursor)
        #expect(defaults.object(forKey: "isPickyCursorEnabled") == nil)
    }

    @Test func migrationRemovesLegacyEnabledFlagWithoutChangingSettings() {
        let store = makeTempStore()
        let defaults = makeDefaults()
        defaults.set(true, forKey: "isPickyCursorEnabled")

        let migrated = CompanionManager.migrateLegacyCursorPreferenceIfNeeded(store: store, defaults: defaults)

        #expect(migrated.cursor.showPiCursor)
        #expect(defaults.object(forKey: "isPickyCursorEnabled") == nil)
    }

    @Test func migrationIsNoOpWithoutLegacyKey() {
        let store = makeTempStore()
        let defaults = makeDefaults()

        let migrated = CompanionManager.migrateLegacyCursorPreferenceIfNeeded(store: store, defaults: defaults)

        #expect(migrated.cursor.showPiCursor)
        #expect(defaults.object(forKey: "isPickyCursorEnabled") == nil)
    }

    // MARK: - Settings-driven overlay lifecycle

    @Test func disablingCursorPreferenceTearsOverlayDownImmediately() async throws {
        let ink = FakeInkCaptureCoordinator()
        let manager = makeManager(initialSettings: settings(showPiCursor: true), ink: ink)

        ink.onStateChange(activeInkState)
        try await waitUntil { manager.isOverlayVisible }

        manager.applyCursorPreferenceFromSettings(settings(showPiCursor: false))

        #expect(!manager.isOverlayVisible)
        #expect(manager.overlayVisibilityReasons.isEmpty)
    }

    @Test func unrelatedSettingsSaveKeepsTransientOverlayVisible() async throws {
        let ink = FakeInkCaptureCoordinator()
        let manager = makeManager(initialSettings: settings(showPiCursor: false), ink: ink)

        ink.onStateChange(activeInkState)
        try await waitUntil { manager.isOverlayVisible }

        // Same preference value — must not tear down the in-flight overlay.
        manager.applyCursorPreferenceFromSettings(settings(showPiCursor: false))

        #expect(manager.isOverlayVisible)
        #expect(manager.overlayVisibilityReasons.contains(.activeInkCapture))
    }

    @Test func enablingCursorPreferenceWithoutPermissionsStaysHidden() {
        let ink = FakeInkCaptureCoordinator()
        let manager = makeManager(initialSettings: settings(showPiCursor: false), ink: ink)

        manager.applyCursorPreferenceFromSettings(settings(showPiCursor: true))

        #expect(!manager.isOverlayVisible)
        #expect(manager.overlayVisibilityReasons.isEmpty)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<50 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(predicate())
    }
}
