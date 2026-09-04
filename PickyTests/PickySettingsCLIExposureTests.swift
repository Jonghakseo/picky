//
//  PickySettingsCLIExposureTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickySettingsCLIExposureTests {
    @Test func exposesNewPickleCompletionDefaultAsReadOnlyMetadata() {
        let entries = PickySettingsCLIExposure.entries

        #expect(entries.map(\.key) == [
            "hud.dockVisible",
            "hud.dockSizePreset",
            "mainAgent.model",
            "mainAgent.thinkingLevel",
            "pickleAgent.model",
            "pickleAgent.thinkingLevel",
            "notifications.newPicklesNotifyOnCompletion",
            "cursor.visible"
        ])
        #expect(entries.first(where: { $0.key == "hud.dockVisible" })?.supportsToggle == true)
        #expect(entries.first(where: { $0.key == "hud.dockSizePreset" })?.choices == ["s", "m", "l"])
        let completionDefault = try? PickySettingsCLIExposure.currentValue(
            for: "notifications.newPicklesNotifyOnCompletion",
            in: PickySettings.defaults()
        )
        #expect(completionDefault == .bool(false))
        #expect(entries.first(where: { $0.key == "notifications.newPicklesNotifyOnCompletion" })?.writable == false)
    }

    @Test func togglesBooleanCatalogValuesAndPreservesPerDisplayVisibilitySemantics() throws {
        var settings = PickySettings.defaults()
        settings.cursor.showPiCursor = true
        settings.hudDockVisible = true

        let cursorValue = try PickySettingsCLIExposure.apply(
            key: "cursor.visible",
            value: .string("toggle"),
            toggle: true,
            displayId: nil,
            to: &settings
        )
        let displayValue = try PickySettingsCLIExposure.apply(
            key: "hud.dockVisible",
            value: .bool(false),
            toggle: false,
            displayId: "42",
            to: &settings
        )

        #expect(cursorValue == .bool(false))
        #expect(settings.cursor.showPiCursor == false)
        #expect(displayValue == .bool(false))
        #expect(settings.hudDockVisibilityByDisplayID == ["42": false])
    }

    @Test func rejectsUnknownKeysInvalidValuesAndMainAgentDeniedEntries() throws {
        do {
            _ = try PickySettingsCLIExposure.entry(for: "not.a.setting")
            Issue.record("Expected unknown catalog key to be rejected")
        } catch let error as PickySettingsCLIExposureError {
            #expect(error.code == "SETTINGS_KEY_UNKNOWN")
        }

        var settings = PickySettings.defaults()
        do {
            _ = try PickySettingsCLIExposure.apply(
                key: "mainAgent.thinkingLevel",
                value: .string("turbo"),
                toggle: false,
                displayId: nil,
                to: &settings
            )
            Issue.record("Expected unsupported enum value to be rejected")
        } catch let error as PickySettingsCLIExposureError {
            #expect(error.code == "SETTINGS_VALUE_INVALID")
        }

        let mainAgentDenied = PickySettingsCLIEntry(
            key: "test.private",
            type: .bool,
            choices: nil,
            writable: true,
            mainAgentAllowed: false,
            supportsToggle: false,
            restartRequired: false,
            description: "Test-only denied setting."
        )
        do {
            try PickySettingsCLIExposure.validateAccess(for: mainAgentDenied, caller: "mainAgent")
            Issue.record("Expected main-agent policy denial")
        } catch let error as PickySettingsCLIExposureError {
            #expect(error.code == "SETTINGS_KEY_NOT_ALLOWED_FOR_MAIN_AGENT")
        }
    }
}
