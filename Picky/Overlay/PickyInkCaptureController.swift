//
//  PickyInkCaptureController.swift
//  Picky
//
//  Captures suppressed, Picky-owned ink while a voice or text input mode is
//  active. The underlying app never receives mouse input during capture; only
//  left click + drag beyond the threshold becomes context ink.
//

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

final class PickyInkCaptureController {
    var onStateChange: (PickyInkOverlayState) -> Void = { _ in }
    var shouldPassThroughMouseEvent: (_ point: CGPoint, _ source: PickyInkCaptureSource) -> Bool = { _, _ in false }

    var isActive: Bool { session != nil }

    private struct Session {
        let id: String
        let source: PickyInkCaptureSource
        let startedAt: Date
        var virtualCursor: CGPoint
        var activeStrokeOrigin: CGPoint?
        var activeStrokePoints: [CGPoint] = []
        var completedStrokes: [[CGPoint]] = []
        var didCrossThreshold = false
        var thresholdFeedbackPoint: CGPoint?
        var lastAcceptedPoint: CGPoint?
    }

    private let thresholdDistance: CGFloat
    private let minimumPointDistance: CGFloat
    private let strokeWidth: CGFloat
    private let strokeOpacity: Double
    private var session: Session?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    /// Sliding window of recent virtual-cursor positions painted as a fading
    /// blue ink trail behind the system pointer to signal "drawing mode".
    /// Filled only while the user is *not* actively dragging an ink stroke,
    /// so the trail never visually competes with the real ink they're drawing.
    private var cursorTrailPoints: [PickyInkCursorTrailPoint] = []
    /// Approx. lifetime in seconds for any single trail entry. The renderer
    /// uses it to compute fade; the controller uses it to drop expired entries
    /// during garbage-collection passes.
    private let trailLifetime: TimeInterval = 0.45
    /// Skip points that landed within this many AppKit points of the previous
    /// trail entry. Avoids spamming the array on every micro-jitter.
    private let trailMinPointDistance: CGFloat = 1.5


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
            virtualCursor: origin
        )
        guard startEventTapIfNeeded() else {
            session = nil
            publishState()
            return false
        }
        publishState()
        return true
    }

    func finish(warpSystemCursor: Bool = false) -> PickyInkCapture? {
        guard let finishedSession = session else { return nil }
        session = nil
        stopEventTap()
        if warpSystemCursor {
            warpSystemCursorToAppKitPoint(finishedSession.virtualCursor)
        }
        publishState()

        let capturedPointLists = capturedStrokePointLists(for: finishedSession)
        guard !capturedPointLists.isEmpty else { return nil }
        let strokes = capturedPointLists.enumerated().map { index, points in
            PickyInkCaptureStroke(
                id: "\(finishedSession.id)-stroke-\(index + 1)",
                source: finishedSession.source,
                points: points.map(PickyCGPoint.init),
                strokeWidth: Double(strokeWidth),
                opacity: strokeOpacity
            )
        }
        return PickyInkCapture(
            id: finishedSession.id,
            source: finishedSession.source,
            startedAt: finishedSession.startedAt,
            endedAt: Date(),
            strokes: strokes
        )
    }

    func cancel() {
        guard session != nil else { return }
        session = nil
        stopEventTap()
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

        guard let currentSession = session else { return Unmanaged.passUnretained(event) }

        let point = appKitPoint(for: event) ?? NSEvent.mouseLocation
        if currentSession.activeStrokeOrigin == nil,
           shouldPassThroughMouseEvent(point, currentSession.source) {
            moveVirtualCursor(to: point)
            return Unmanaged.passUnretained(event)
        }

        switch eventType {
        case .mouseMoved, .rightMouseDragged, .otherMouseDragged,
             .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            moveVirtualCursor(to: point)
        case .leftMouseDown:
            beginPotentialStroke(at: point)
        case .leftMouseDragged:
            updatePotentialStroke(to: point)
        case .leftMouseUp:
            finishPotentialStroke(at: point)
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

    private func moveVirtualCursor(to point: CGPoint) {
        guard var current = session else { return }
        current.virtualCursor = point
        if current.activeStrokeOrigin == nil {
            appendCursorTrailPoint(point)
        }
        session = current
        publishState()
    }

    private func beginPotentialStroke(at point: CGPoint) {
        guard var current = session else { return }
        current.virtualCursor = point
        current.activeStrokeOrigin = point
        current.activeStrokePoints = []
        current.lastAcceptedPoint = nil
        current.didCrossThreshold = false
        current.thresholdFeedbackPoint = nil
        // Don't let the trail bleed into the real stroke about to be drawn.
        cursorTrailPoints.removeAll(keepingCapacity: true)
        session = current
        publishState()
    }

    private func updatePotentialStroke(to point: CGPoint) {
        guard var current = session else { return }
        current.virtualCursor = point
        guard let origin = current.activeStrokeOrigin else {
            session = current
            publishState()
            return
        }

        if current.activeStrokePoints.isEmpty {
            let distanceFromOrigin = hypot(point.x - origin.x, point.y - origin.y)
            guard distanceFromOrigin >= thresholdDistance else {
                session = current
                publishState()
                return
            }
            current.didCrossThreshold = true
            current.thresholdFeedbackPoint = point
            current.activeStrokePoints = [origin, point]
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
        current.activeStrokePoints.append(point)
        current.lastAcceptedPoint = point
        session = current
        publishState()
    }

    private func finishPotentialStroke(at point: CGPoint) {
        guard var current = session else { return }
        current.virtualCursor = point
        if let origin = current.activeStrokeOrigin, current.activeStrokePoints.isEmpty {
            let distanceFromOrigin = hypot(point.x - origin.x, point.y - origin.y)
            if distanceFromOrigin >= thresholdDistance {
                current.activeStrokePoints = [origin, point]
            }
        } else if current.activeStrokePoints.count >= 2,
                  let lastAcceptedPoint = current.lastAcceptedPoint,
                  hypot(point.x - lastAcceptedPoint.x, point.y - lastAcceptedPoint.y) >= minimumPointDistance {
            current.activeStrokePoints.append(point)
        }

        if current.activeStrokePoints.count >= 2 {
            current.completedStrokes.append(current.activeStrokePoints)
        }
        current.activeStrokeOrigin = nil
        current.activeStrokePoints = []
        current.lastAcceptedPoint = nil
        current.didCrossThreshold = false
        current.thresholdFeedbackPoint = nil
        session = current
        publishState()
    }

    private func publishState() {
        guard let session else {
            cursorTrailPoints.removeAll(keepingCapacity: false)
            onStateChange(.inactive)
            return
        }
        let strokes = capturedStrokePointLists(for: session).enumerated().map { index, points in
            PickyInkOverlayStroke(
                id: "\(session.id)-stroke-\(index + 1)",
                points: points,
                strokeWidth: strokeWidth,
                opacity: strokeOpacity
            )
        }
        // Hide the trail entirely while the user is mid-stroke — the real
        // ink is being drawn at the same coordinates and would clash.
        let trail = session.activeStrokeOrigin == nil ? cursorTrailPoints : []
        onStateChange(PickyInkOverlayState(
            isActive: true,
            source: session.source,
            virtualCursorGlobalPoint: session.virtualCursor,
            strokes: strokes,
            didCrossThreshold: session.didCrossThreshold,
            thresholdFeedbackGlobalPoint: session.thresholdFeedbackPoint,
            cursorTrailPoints: trail
        ))
    }

    private func appendCursorTrailPoint(_ point: CGPoint) {
        let now = CACurrentMediaTime()
        if let last = cursorTrailPoints.last,
           hypot(point.x - last.point.x, point.y - last.point.y) < trailMinPointDistance {
            return
        }
        cursorTrailPoints.append(
            PickyInkCursorTrailPoint(id: UUID(), point: point, capturedAt: now)
        )
        // GC: drop entries past their lifetime so the array doesn't grow
        // unbounded if the user idles the mouse for a long time.
        let cutoff = now - trailLifetime
        if let firstFresh = cursorTrailPoints.firstIndex(where: { $0.capturedAt >= cutoff }), firstFresh > 0 {
            cursorTrailPoints.removeFirst(firstFresh)
        }
    }

    private func capturedStrokePointLists(for session: Session) -> [[CGPoint]] {
        var pointLists = session.completedStrokes.filter { $0.count >= 2 }
        if session.activeStrokePoints.count >= 2 {
            pointLists.append(session.activeStrokePoints)
        }
        return pointLists
    }

    private func warpSystemCursorToAppKitPoint(_ point: CGPoint) {
        // The live system cursor usually continues tracking even while its
        // events are suppressed. Avoid coordinate-system surprises by only
        // warping when a caller explicitly opts in.
        _ = point
    }
}
