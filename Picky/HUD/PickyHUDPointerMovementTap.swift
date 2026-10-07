//
//  PickyHUDPointerMovementTap.swift
//  Picky
//
//  Observes system-wide pointer movement for the HUD panel's click-through
//  routing while Picky is not the active app.
//
//  Do not replace this with `NSEvent.addGlobalMonitorForEvents` for
//  `.mouseMoved`. While Picky is inactive, any global mouse-moved monitor in
//  the process delays or drops `NSTrackingArea` enter events until the pointer
//  moves again: dock rows missed or lagged their hover in roughly half of the
//  row changes, while a listen-only tap left every enter on time. A mouse-only
//  listen tap needs no Input Monitoring grant. See docs/perf-profiling.md and
//  `checkGlobalPointerMonitorBoundary` in scripts/check-architecture-rules.js.
//

import AppKit

final class PickyHUDPointerMovementTap {
    private let onMove: () -> Void
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    init(onMove: @escaping () -> Void) {
        self.onMove = onMove
    }

    deinit {
        stop()
    }

    var isRunning: Bool { eventTap != nil }

    @discardableResult
    func start() -> Bool {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return false }
        guard eventTap == nil else { return true }
        let eventTypes: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { mask, eventType in
            mask | (CGEventMask(1) << eventType.rawValue)
        }

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let pointerTap = Unmanaged<PickyHUDPointerMovementTap>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            pointerTap.handleEventTap(eventType: eventType)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            PickyLog.notice(.sessionUI, prefix: "⚠️", message: "Picky HUD: couldn't create pointer movement tap")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            PickyLog.notice(
                .sessionUI,
                prefix: "⚠️",
                message: "Picky HUD: couldn't create pointer movement run loop source"
            )
            return false
        }

        eventTap = tap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handleEventTap(eventType: CGEventType) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        onMove()
    }
}
