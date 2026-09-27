//
//  PickyPanelKeyboardShortcutTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyPanelKeyboardShortcutTests {
    @Test func closeShortcutMatchesCommandWAndKoreanPhysicalW() throws {
        let commandW = try Self.keyEvent(characters: "w", keyCode: 13)
        #expect(PickyPanelKeyboardShortcut.isCloseWindowShortcut(commandW))

        let koreanPhysicalW = try Self.keyEvent(characters: "ㅈ", keyCode: 13)
        #expect(PickyPanelKeyboardShortcut.isCloseWindowShortcut(koreanPhysicalW))
    }

    @Test func closeShortcutRequiresPlainCommandW() throws {
        let commandR = try Self.keyEvent(characters: "r", keyCode: 15)
        #expect(!PickyPanelKeyboardShortcut.isCloseWindowShortcut(commandR))

        let commandShiftW = try Self.keyEvent(characters: "W", modifiers: [.command, .shift], keyCode: 13)
        #expect(!PickyPanelKeyboardShortcut.isCloseWindowShortcut(commandShiftW))
    }

    @Test func windowHelperPerformsCloseOnlyForCloseShortcut() throws {
        let window = CloseCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let ignored = try Self.keyEvent(characters: "r", keyCode: 15)
        #expect(!window.handlePickyCloseWindowShortcut(ignored))
        #expect(window.performCloseCallCount == 0)

        let close = try Self.keyEvent(characters: "w", keyCode: 13)
        #expect(window.handlePickyCloseWindowShortcut(close))
        #expect(window.performCloseCallCount == 1)
    }

    @Test func hudPanelRoutesFirstCloseKeyEquivalentToCardCloseRequest() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var closeRequestCount = 0
        panel.onCloseRequested = { closeRequestCount += 1 }
        let close = try Self.keyEvent(characters: "w", keyCode: 13)

        #expect(panel.performKeyEquivalent(with: close))
        #expect(closeRequestCount == 1)
    }

    @Test func hudPanelRoutesDirectFirstCloseEventToCardCloseRequest() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var closeRequestCount = 0
        panel.onCloseRequested = { closeRequestCount += 1 }
        let close = try Self.keyEvent(characters: "w", keyCode: 13)

        panel.sendEvent(close)

        #expect(closeRequestCount == 1)
    }

    @Test func minimizedDockOnlyAcceptsPointerOverRestoreChromeAndDoesNotClaimCommandW() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 100, y: 200, width: 600, height: 500),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        var closes = 0
        panel.onCloseRequested = { closes += 1 }
        panel.acceptsMouseMovedEvents = false
        panel.minimizedVisibleChromeFrames = [CGRect(x: 20, y: 30, width: 32, height: 32)]
        panel.isDockMinimized = true
        #expect(panel.acceptsMouseMovedEvents)

        // A click over the former card/rail must be delivered to the application below.
        panel.updateMinimizedDockPointer(CGPoint(x: 400, y: 400))
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.performKeyEquivalent(with: try Self.keyEvent(characters: "w", keyCode: 13)))
        #expect(closes == 0)

        panel.setMinimizedPointerCapture(true)
        panel.updateMinimizedDockPointer(CGPoint(x: 400, y: 400))
        #expect(!panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        panel.setMinimizedPointerCapture(false)
        panel.updateMinimizedDockPointer(CGPoint(x: 400, y: 400))
        #expect(panel.ignoresMouseEvents)

        // The actual AppKit flag re-enables pointer delivery only over the 32pt logo.
        panel.updateMinimizedDockPointer(CGPoint(x: 136, y: 654))
        #expect(!panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        panel.minimizedVisibleChromeFrames = []
        panel.updateMinimizedDockPointer(CGPoint(x: 136, y: 654))
        #expect(panel.ignoresMouseEvents)

        panel.prepareForSessionFocus()
        #expect(!panel.acceptsMouseMovedEvents)
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.canBecomeKey)
        #expect(panel.performKeyEquivalent(with: try Self.keyEvent(characters: "w", keyCode: 13)))
        #expect(closes == 1)
    }

    private static func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags = .command,
        keyCode: UInt16
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

private final class CloseCountingWindow: NSWindow {
    private(set) var performCloseCallCount = 0

    override func performClose(_ sender: Any?) {
        performCloseCallCount += 1
    }
}
