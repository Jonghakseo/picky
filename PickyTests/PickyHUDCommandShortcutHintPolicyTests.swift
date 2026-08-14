import AppKit
import Testing
@testable import Picky

@Suite("HUD Command shortcut hint policy")
struct PickyHUDCommandShortcutHintPolicyTests {
    @Test func modifierFlagsShowHintOnlyForCurrentHUDPanelWhileCommandIsPressed() {
        #expect(PickyHUDCommandShortcutHintPolicy.visibility(
            current: false,
            after: .modifierFlagsChanged(modifierFlags: .command, isCurrentHUDPanelKey: true)
        ))
        #expect(!PickyHUDCommandShortcutHintPolicy.visibility(
            current: true,
            after: .modifierFlagsChanged(modifierFlags: .command, isCurrentHUDPanelKey: false)
        ))
        #expect(!PickyHUDCommandShortcutHintPolicy.visibility(
            current: true,
            after: .modifierFlagsChanged(modifierFlags: [], isCurrentHUDPanelKey: true)
        ))
    }

    @Test func currentHUDPanelResigningKeyClearsHintWithoutModifierRelease() {
        let visible = PickyHUDCommandShortcutHintPolicy.visibility(
            current: false,
            after: .modifierFlagsChanged(modifierFlags: .command, isCurrentHUDPanelKey: true)
        )

        let hidden = PickyHUDCommandShortcutHintPolicy.visibility(
            current: visible,
            after: .hudPanelDidResignKey(isCurrentHUDPanel: true)
        )

        #expect(visible)
        #expect(!hidden)
    }

    @Test func unrelatedWindowResigningKeyPreservesCurrentHintState() {
        let visible = PickyHUDCommandShortcutHintPolicy.visibility(
            current: true,
            after: .hudPanelDidResignKey(isCurrentHUDPanel: false)
        )

        #expect(visible)
    }
}
