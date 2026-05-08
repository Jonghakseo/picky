//
//  PickyInkCaptureController.swift
//  Picky
//
//  Captures mouse motion as suppressed, Picky-owned ink while a voice or text
//  input mode is active. The underlying app never receives mouse input during
//  capture; small movements stay as cursor motion only until the threshold is
//  crossed.
//

import AppKit
import CoreGraphics
import Foundation

final class PickyInkCaptureController {
    var onStateChange: (PickyInkOverlayState) -> Void = { _ in }

    var isActive: Bool { session != nil }

    private struct Session {
        let id: String
        let source: PickyInkCaptureSource
        let startedAt: Date
        let origin: CGPoint
        var virtualCursor: CGPoint
        var didCrossThreshold = false
        var thresholdFeedbackPoint: CGPoint?
        var strokePoints: [CGPoint] = []
        var lastAcceptedPoint: CGPoint?
    }

    private let thresholdDistance: CGFloat
    private let minimumPointDistance: CGFloat
    private let strokeWidth: CGFloat
    private let strokeOpacity: Double
    private var session: Session?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var cursorHideBalance = 0

    init(
        thresholdDistance: CGFloat = 28,
        minimumPointDistance: CGFloat = 3,
        strokeWidth: CGFloat = 8,
        strokeOpacity: Double = 0.34
    ) {
        self.thresholdDistance = thresholdDistance
        self.minimumPointDistance = minimumPointDistance
        self.strokeWidth = strokeWidth
        self.strokeOpacity = strokeOpacity
    }

    deinit {
        stopEventTap()
        restoreSystemCursorIfNeeded()
    }

    @discardableResult
    func begin(source: PickyInkCaptureSource, origin: CGPoint = NSEvent.mouseLocation) -> Bool {
        if isActive {
            _ = finish(warpSystemCursor: false)
        }
        session = Session(
            id: "ink-\(UUID().uuidString)",
            source: source,
            startedAt: Date(),
            origin: origin,
            virtualCursor: origin
        )
        guard startEventTapIfNeeded() else {
            session = nil
            publishState()
            return false
        }
        hideSystemCursorIfNeeded()
        publishState()
        return true
    }

    func finish(warpSystemCursor: Bool = false) -> PickyInkCapture? {
        guard let finishedSession = session else { return nil }
        session = nil
        stopEventTap()
        restoreSystemCursorIfNeeded()
        if warpSystemCursor {
            warpSystemCursorToAppKitPoint(finishedSession.virtualCursor)
        }
        publishState()

        guard finishedSession.didCrossThreshold,
              finishedSession.strokePoints.count >= 2 else { return nil }
        let stroke = PickyInkCaptureStroke(
            id: "\(finishedSession.id)-stroke-1",
            source: finishedSession.source,
            points: finishedSession.strokePoints.map(PickyCGPoint.init),
            strokeWidth: Double(strokeWidth),
            opacity: strokeOpacity
        )
        return PickyInkCapture(
            id: finishedSession.id,
            source: finishedSession.source,
            startedAt: finishedSession.startedAt,
            endedAt: Date(),
            strokes: [stroke]
        )
    }

    func cancel() {
        guard session != nil else { return }
        session = nil
        stopEventTap()
        restoreSystemCursorIfNeeded()
        publishState()
    }

    private func startEventTapIfNeeded() -> Bool {
        guard eventTap == nil else { return true }
        let eventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
            .rightMouseDown,
            .rightMouseUp,
            .rightMouseDragged,
            .otherMouseDown,
            .otherMouseUp,
            .otherMouseDragged,
            .scrollWheel
        ]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { mask, eventType in
            mask | (CGEventMask(1) << eventType.rawValue)
        }

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<PickyInkCaptureController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return controller.handleEventTap(eventType: eventType, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Picky ink: couldn't create mouse event tap")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            print("⚠️ Picky ink: couldn't create event tap run loop source")
            return false
        }

        eventTap = tap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopEventTap() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handleEventTap(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return nil
        }

        guard session != nil else { return Unmanaged.passUnretained(event) }

        switch eventType {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            updateVirtualCursor(to: appKitPoint(for: event) ?? NSEvent.mouseLocation)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            updateVirtualCursor(to: appKitPoint(for: event) ?? NSEvent.mouseLocation)
        default:
            break
        }

        // Suppress all mouse input while Picky owns ink capture.
        return nil
    }

    private func appKitPoint(for event: CGEvent) -> CGPoint? {
        let quartzPoint = event.location
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            let quartzBounds = CGDisplayBounds(displayID)
            guard quartzBounds.insetBy(dx: -1, dy: -1).contains(quartzPoint) else { continue }
            let localX = quartzPoint.x - quartzBounds.origin.x
            let localYFromTop = quartzPoint.y - quartzBounds.origin.y
            return CGPoint(
                x: screen.frame.origin.x + localX,
                y: screen.frame.origin.y + screen.frame.height - localYFromTop
            )
        }
        return nil
    }

    private func updateVirtualCursor(to point: CGPoint) {
        guard var current = session else { return }
        current.virtualCursor = point

        let distanceFromOrigin = hypot(point.x - current.origin.x, point.y - current.origin.y)
        if !current.didCrossThreshold {
            guard distanceFromOrigin >= thresholdDistance else {
                session = current
                publishState()
                return
            }
            current.didCrossThreshold = true
            current.thresholdFeedbackPoint = point
            current.strokePoints = [current.origin, point]
            current.lastAcceptedPoint = point
            session = current
            publishState()
            return
        }

        if let lastAcceptedPoint = current.lastAcceptedPoint {
            let distance = hypot(point.x - lastAcceptedPoint.x, point.y - lastAcceptedPoint.y)
            guard distance >= minimumPointDistance else {
                session = current
                publishState()
                return
            }
        }
        current.strokePoints.append(point)
        current.lastAcceptedPoint = point
        session = current
        publishState()
    }

    private func publishState() {
        guard let session else {
            onStateChange(.inactive)
            return
        }
        let stroke: PickyInkOverlayStroke?
        if session.didCrossThreshold, session.strokePoints.count >= 2 {
            stroke = PickyInkOverlayStroke(
                id: "\(session.id)-stroke-1",
                points: session.strokePoints,
                strokeWidth: strokeWidth,
                opacity: strokeOpacity
            )
        } else {
            stroke = nil
        }
        onStateChange(PickyInkOverlayState(
            isActive: true,
            source: session.source,
            virtualCursorGlobalPoint: session.virtualCursor,
            strokes: stroke.map { [$0] } ?? [],
            didCrossThreshold: session.didCrossThreshold,
            thresholdFeedbackGlobalPoint: session.thresholdFeedbackPoint
        ))
    }

    private func hideSystemCursorIfNeeded() {
        guard cursorHideBalance == 0 else { return }
        NSCursor.hide()
        cursorHideBalance = 1
    }

    private func restoreSystemCursorIfNeeded() {
        guard cursorHideBalance > 0 else { return }
        for _ in 0..<cursorHideBalance {
            NSCursor.unhide()
        }
        cursorHideBalance = 0
    }

    private func warpSystemCursorToAppKitPoint(_ point: CGPoint) {
        // The live system cursor usually continues tracking even while its
        // events are suppressed. Avoid coordinate-system surprises by only
        // warping when a caller explicitly opts in.
        _ = point
    }
}
