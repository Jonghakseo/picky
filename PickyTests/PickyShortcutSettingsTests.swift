import AppKit
import Foundation
import Testing
@testable import Picky

struct PickyShortcutSettingsTests {
    @Test func shortcutSettingsRoundTripIncludesFocusPickleShortcut() throws {
        var settings = PickySettings.defaults(seedDefaultWorkspace: false)
        settings.pushToTalkShortcut = .modifierCombo(modifiers: [.control], keyCode: 49)
        settings.quickInputShortcut = .doubleTapModifier(.option)
        settings.focusPickleShortcut = .modifierCombo(modifiers: [.option], keyCode: 3)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PickySettings.self, from: data)

        #expect(decoded.pushToTalkShortcut == settings.pushToTalkShortcut)
        #expect(decoded.quickInputShortcut == settings.quickInputShortcut)
        #expect(decoded.focusPickleShortcut == settings.focusPickleShortcut)
    }

    @Test func missingFocusPickleShortcutUsesDefaultWithoutChangingExistingShortcuts() throws {
        var settings = PickySettings.defaults(seedDefaultWorkspace: false)
        settings.pushToTalkShortcut = .modifierCombo(modifiers: [.shift], keyCode: 6)
        settings.quickInputShortcut = .doubleTapModifier(.option)
        var object = try jsonObject(settings)
        object.removeValue(forKey: "focusPickleShortcut")

        let decoded = try decode(object)

        #expect(decoded.pushToTalkShortcut == settings.pushToTalkShortcut)
        #expect(decoded.quickInputShortcut == settings.quickInputShortcut)
        #expect(decoded.focusPickleShortcut == .defaultFocusPickle)
    }

    @Test func malformedFocusPickleShortcutRecoversOnlyThatField() throws {
        var settings = PickySettings.defaults(seedDefaultWorkspace: false)
        settings.pushToTalkShortcut = .modifierCombo(modifiers: [.shift], keyCode: 6)
        settings.quickInputShortcut = .doubleTapModifier(.option)
        var object = try jsonObject(settings)
        object["focusPickleShortcut"] = [
            "kind": "physicalModifierChord",
            "physicalKeys": ["not-a-real-key"],
        ]

        let decoded = try decode(object)

        #expect(decoded.pushToTalkShortcut == settings.pushToTalkShortcut)
        #expect(decoded.quickInputShortcut == settings.quickInputShortcut)
        #expect(decoded.focusPickleShortcut == .defaultFocusPickle)
    }

    @Test func conflictPolicyChecksAllOtherShortcutRolesSymmetrically() {
        let shortcuts: [PickyShortcutRole: PickyShortcutSpec] = [
            .pushToTalk: .modifierCombo(modifiers: .command, keyCode: nil),
            .quickInput: .doubleTapModifier(.control),
            .focusPickle: .defaultFocusPickle,
        ]

        #expect(PickyShortcutConflictPolicy.conflictingRole(
            for: .defaultFocusPickle,
            role: .focusPickle,
            shortcuts: shortcuts
        ) == .pushToTalk)
        #expect(PickyShortcutConflictPolicy.conflictingRole(
            for: .modifierCombo(modifiers: .command, keyCode: nil),
            role: .pushToTalk,
            shortcuts: shortcuts
        ) == .focusPickle)
    }

    private func jsonObject(_ settings: PickySettings) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> PickySettings {
        try JSONDecoder().decode(
            PickySettings.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}
