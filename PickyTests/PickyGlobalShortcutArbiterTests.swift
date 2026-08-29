import AppKit
import Combine
import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyGlobalShortcutArbiterTests {
    @Test func defaultPhysicalChordPublishesFocusExactlyOnceUntilFullRelease() {
        let arbiter = PickyGlobalShortcutArbiter()
        var focusEvents: [PickyFocusPickleShortcutEvent] = []
        let cancellable = arbiter.focusPicklePublisher.sink { focusEvents.append($0) }
        defer { cancellable.cancel() }
        let base = Date(timeIntervalSince1970: 2_000)

        #expect(arbiter.handle(
            physicalEvent(key: .leftCommand, isDown: true, date: base),
            wasPushToTalkPreviouslyPressed: false
        ) == .none)
        #expect(arbiter.handle(
            physicalEvent(key: .rightCommand, isDown: true, date: base.addingTimeInterval(0.04)),
            wasPushToTalkPreviouslyPressed: false
        ) == .none)
        #expect(focusEvents.count == 1)

        _ = arbiter.handle(
            physicalEvent(key: .rightCommand, isDown: true, date: base.addingTimeInterval(0.05)),
            wasPushToTalkPreviouslyPressed: false
        )
        #expect(focusEvents.count == 1)
    }

    @Test func conflictingCommandOnlyPushToTalkWinsOverFocusChord() {
        let arbiter = PickyGlobalShortcutArbiter()
        arbiter.pushToTalkSpec = .modifierCombo(modifiers: .command, keyCode: nil)
        var focusCount = 0
        let cancellable = arbiter.focusPicklePublisher.sink { _ in focusCount += 1 }
        defer { cancellable.cancel() }
        let base = Date(timeIntervalSince1970: 3_000)

        let first = arbiter.handle(
            physicalEvent(key: .leftCommand, isDown: true, date: base),
            wasPushToTalkPreviouslyPressed: false
        )
        let second = arbiter.handle(
            physicalEvent(key: .rightCommand, isDown: true, date: base.addingTimeInterval(0.03)),
            wasPushToTalkPreviouslyPressed: true
        )

        #expect(first == .pressed)
        #expect(second == .none)
        #expect(focusCount == 0)
    }

    @Test func claimedFocusChordSuppressesOverlappingCommandKeyQuickInput() {
        let arbiter = PickyGlobalShortcutArbiter()
        arbiter.quickInputSpec = .modifierCombo(modifiers: .command, keyCode: 49)
        var quickInputCount = 0
        let cancellable = arbiter.quickInputDetector.eventPublisher.sink { _ in quickInputCount += 1 }
        defer { cancellable.cancel() }
        let base = Date(timeIntervalSince1970: 4_000)

        _ = arbiter.handle(
            physicalEvent(key: .leftCommand, isDown: true, date: base),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            physicalEvent(key: .rightCommand, isDown: true, date: base.addingTimeInterval(0.02)),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            rawEvent(type: .keyDown, keyCode: 49, flags: .command, date: base.addingTimeInterval(0.03)),
            wasPushToTalkPreviouslyPressed: false
        )
        #expect(quickInputCount == 0)

        _ = arbiter.handle(
            physicalEvent(key: .leftCommand, isDown: false, date: base.addingTimeInterval(0.04), flags: .command),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            physicalEvent(key: .rightCommand, isDown: false, date: base.addingTimeInterval(0.05)),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            physicalEvent(key: .leftCommand, isDown: true, date: base.addingTimeInterval(0.10)),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            rawEvent(type: .keyDown, keyCode: 49, flags: .command, date: base.addingTimeInterval(0.11)),
            wasPushToTalkPreviouslyPressed: false
        )
        #expect(quickInputCount == 1)
    }

    @Test func claimedQuickInputCancelsLowerPriorityFocusCandidate() {
        let arbiter = PickyGlobalShortcutArbiter()
        arbiter.quickInputSpec = .modifierCombo(modifiers: .command, keyCode: 49)
        var quickInputCount = 0
        var focusCount = 0
        let quickInputCancellable = arbiter.quickInputDetector.eventPublisher.sink { _ in
            quickInputCount += 1
        }
        let focusCancellable = arbiter.focusPicklePublisher.sink { _ in focusCount += 1 }
        defer {
            quickInputCancellable.cancel()
            focusCancellable.cancel()
        }
        let base = Date(timeIntervalSince1970: 4_500)

        _ = arbiter.handle(
            physicalEvent(key: .leftCommand, isDown: true, date: base),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            rawEvent(type: .keyDown, keyCode: 49, flags: .command, date: base.addingTimeInterval(0.01)),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            rawEvent(type: .keyUp, keyCode: 49, flags: .command, date: base.addingTimeInterval(0.02)),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            physicalEvent(key: .rightCommand, isDown: true, date: base.addingTimeInterval(0.03)),
            wasPushToTalkPreviouslyPressed: false
        )

        #expect(quickInputCount == 1)
        #expect(focusCount == 0)
    }

    @Test func reboundModifierKeyComboPublishesFocusAtCapturedMouseLocation() {
        let arbiter = PickyGlobalShortcutArbiter()
        arbiter.focusPickleSpec = .modifierCombo(modifiers: .option, keyCode: 3)
        var focusEvents: [PickyFocusPickleShortcutEvent] = []
        let cancellable = arbiter.focusPicklePublisher.sink { focusEvents.append($0) }
        defer { cancellable.cancel() }
        let base = Date(timeIntervalSince1970: 4_800)

        _ = arbiter.handle(
            rawEvent(type: .flagsChanged, keyCode: 58, flags: .option, date: base),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            rawEvent(type: .keyDown, keyCode: 3, flags: .option, date: base.addingTimeInterval(0.01)),
            wasPushToTalkPreviouslyPressed: false
        )

        #expect(focusEvents == [PickyFocusPickleShortcutEvent(
            mouseLocation: CGPoint(x: 200, y: 300)
        )])
    }

    @Test func reboundDoubleTapModifierPublishesFocus() async throws {
        let arbiter = PickyGlobalShortcutArbiter()
        arbiter.focusPickleSpec = .doubleTapModifier(.option)
        var focusCount = 0
        let cancellable = arbiter.focusPicklePublisher.sink { _ in focusCount += 1 }
        defer { cancellable.cancel() }
        let base = Date(timeIntervalSince1970: 4_900)

        _ = arbiter.handle(
            rawEvent(type: .flagsChanged, keyCode: 58, flags: .option, date: base),
            wasPushToTalkPreviouslyPressed: false
        )
        try await Task.sleep(for: .milliseconds(120))
        _ = arbiter.handle(
            rawEvent(type: .flagsChanged, keyCode: 58, flags: [], date: base.addingTimeInterval(0.12)),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            rawEvent(type: .flagsChanged, keyCode: 58, flags: .option, date: base.addingTimeInterval(0.20)),
            wasPushToTalkPreviouslyPressed: false
        )
        try await Task.sleep(for: .milliseconds(120))

        #expect(focusCount == 1)
    }

    @Test func heldPushToTalkSuppressesOverlappingQuickInputCombo() {
        let arbiter = PickyGlobalShortcutArbiter()
        arbiter.pushToTalkSpec = .modifierCombo(modifiers: [.control, .option], keyCode: nil)
        arbiter.quickInputSpec = .modifierCombo(modifiers: [.control, .option], keyCode: 49)
        var quickInputCount = 0
        let cancellable = arbiter.quickInputDetector.eventPublisher.sink { _ in quickInputCount += 1 }
        defer { cancellable.cancel() }
        let base = Date(timeIntervalSince1970: 5_000)

        let pressed = arbiter.handle(
            rawEvent(type: .flagsChanged, keyCode: 58, flags: [.control, .option], date: base),
            wasPushToTalkPreviouslyPressed: false
        )
        _ = arbiter.handle(
            rawEvent(type: .keyDown, keyCode: 49, flags: [.control, .option], date: base.addingTimeInterval(0.01)),
            wasPushToTalkPreviouslyPressed: true
        )

        #expect(pressed == .pressed)
        #expect(quickInputCount == 0)
    }

    private func physicalEvent(
        key: PickyPhysicalModifierKey,
        isDown: Bool,
        date: Date,
        flags: NSEvent.ModifierFlags? = nil
    ) -> PickyGlobalShortcutRawEvent {
        rawEvent(
            type: .flagsChanged,
            keyCode: key.keyCode,
            flags: flags ?? (isDown ? .command : []),
            isPhysicalModifierDown: isDown,
            date: date
        )
    }

    private func rawEvent(
        type: CGEventType,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        isPhysicalModifierDown: Bool? = nil,
        date: Date
    ) -> PickyGlobalShortcutRawEvent {
        PickyGlobalShortcutRawEvent(
            eventType: type,
            keyCode: keyCode,
            modifierFlagsRawValue: UInt64(flags.rawValue),
            isAutorepeat: false,
            isPhysicalModifierDown: isPhysicalModifierDown,
            mouseLocation: CGPoint(x: 200, y: 300),
            observedAt: date
        )
    }
}
