//
//  PickyHUDDockReorderDragController.swift
//  Picky
//
//  AppKit event monitor that keeps a dock reorder alive while SwiftUI reparents
//  the dragged icon across group boundaries.
//

import AppKit
import Combine

/// Tracks the lifetime of one SwiftUI folder-tile gesture. Cancellation holds
/// the current gesture terminal until its matching end callback arrives, so a
/// view update cannot reinterpret a later change from the same mouse press as
/// a new drag.
struct PickyDockGroupDragGestureLifecycle: Equatable {
    private enum State: Equatable {
        case idle
        case active(groupID: String)
        case cancelledAwaitingEnd(groupID: String)
    }

    private var state: State = .idle

    /// Returns whether a change belongs to an active gesture. The first change
    /// starts the gesture; later changes after cancellation are deliberately
    /// ignored until `finish(groupID:)` or the rail-level physical mouse-up
    /// monitor observes the release.
    mutating func acceptChange(groupID: String) -> Bool {
        switch state {
        case .idle:
            state = .active(groupID: groupID)
            return true
        case .active(let activeGroupID):
            return activeGroupID == groupID
        case .cancelledAwaitingEnd:
            return false
        }
    }

    mutating func cancel() {
        guard case .active(let groupID) = state else { return }
        state = .cancelledAwaitingEnd(groupID: groupID)
    }

    /// Returns true only when the matching gesture remained active through its
    /// release. Either terminal path restores idle so a deliberate later drag
    /// can start normally.
    mutating func finish(groupID: String) -> Bool {
        switch state {
        case .active(let activeGroupID) where activeGroupID == groupID:
            state = .idle
            return true
        case .cancelledAwaitingEnd(let cancelledGroupID) where cancelledGroupID == groupID:
            state = .idle
            return false
        default:
            return false
        }
    }

    /// Restores idle only when a persisted update cancelled the active gesture.
    /// This is driven by the rail, which survives when the original folder tile
    /// disappears before SwiftUI can send its matching `onEnded` callback.
    mutating func finishCancelledGestureOnPhysicalRelease() -> Bool {
        guard case .cancelledAwaitingEnd = state else { return false }
        state = .idle
        return true
    }
}

/// Retains a rail-level mouse-up source while a folder drag is active. Unlike
/// the folder tile's SwiftUI gesture, the rail remains alive when a persisted
/// structure update removes the dragged tile.
@MainActor
final class PickyDockGroupDragReleaseMonitor {
    typealias LocalEventMonitorInstaller = (
        _ mask: NSEvent.EventTypeMask,
        _ handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any?
    typealias LocalEventMonitorRemover = (_ monitor: Any) -> Void

    private let allowsUserEnvironmentEffects: Bool
    private let installLocalMonitor: LocalEventMonitorInstaller
    private let removeLocalMonitor: LocalEventMonitorRemover
    private var monitor: Any?
    private var onCancelledRelease: (() -> Bool)?

    init(
        allowsUserEnvironmentEffects: Bool = PickyRuntimeEnvironment.allowsUserEnvironmentEffects,
        installLocalMonitor: @escaping LocalEventMonitorInstaller = { mask, handler in
            NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        },
        removeLocalMonitor: @escaping LocalEventMonitorRemover = { monitor in
            NSEvent.removeMonitor(monitor)
        }
    ) {
        self.allowsUserEnvironmentEffects = allowsUserEnvironmentEffects
        self.installLocalMonitor = installLocalMonitor
        self.removeLocalMonitor = removeLocalMonitor
    }

    func begin(onCancelledRelease: @escaping () -> Bool) {
        guard allowsUserEnvironmentEffects, monitor == nil else { return }
        self.onCancelledRelease = onCancelledRelease
        monitor = installLocalMonitor(.leftMouseUp) { [weak self] event in
            guard let self, self.onCancelledRelease?() == true else { return event }
            self.stop()
            return event
        }
    }

    func stop() {
        if let monitor { removeLocalMonitor(monitor) }
        monitor = nil
        onCancelledRelease = nil
    }

    deinit {
        if let monitor { removeLocalMonitor(monitor) }
    }
}

@MainActor
final class PickyDockReorderDragController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case dragging(sessionID: String, translation: CGSize)
        case ended(sessionID: String, translation: CGSize)
    }

    typealias LocalEventMonitorInstaller = (
        _ mask: NSEvent.EventTypeMask,
        _ handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any?
    typealias LocalEventMonitorRemover = (_ monitor: Any) -> Void

    @Published private(set) var phase: Phase = .idle

    private let allowsUserEnvironmentEffects: Bool
    private let installLocalMonitor: LocalEventMonitorInstaller
    private let removeLocalMonitor: LocalEventMonitorRemover
    private var monitor: Any?
    private var anchorScreenPoint: NSPoint = .zero
    private var sessionID: String?

    init(
        allowsUserEnvironmentEffects: Bool = PickyRuntimeEnvironment.allowsUserEnvironmentEffects,
        installLocalMonitor: @escaping LocalEventMonitorInstaller = { mask, handler in
            NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        },
        removeLocalMonitor: @escaping LocalEventMonitorRemover = { monitor in
            NSEvent.removeMonitor(monitor)
        }
    ) {
        self.allowsUserEnvironmentEffects = allowsUserEnvironmentEffects
        self.installLocalMonitor = installLocalMonitor
        self.removeLocalMonitor = removeLocalMonitor
    }

    func begin(sessionID: String, anchorScreenPoint: NSPoint) {
        guard allowsUserEnvironmentEffects else { return }
        reset()
        self.sessionID = sessionID
        self.anchorScreenPoint = anchorScreenPoint
        phase = .dragging(sessionID: sessionID, translation: currentTranslation())
        monitor = installLocalMonitor([.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let sessionID = self.sessionID else { return event }
            let translation = self.currentTranslation()
            switch event.type {
            case .leftMouseUp:
                self.phase = .ended(sessionID: sessionID, translation: translation)
                self.invalidateNativeTracking()
                return nil
            default:
                self.phase = .dragging(sessionID: sessionID, translation: translation)
                return nil
            }
        }
    }

    /// Cancels the active reorder without emitting an end phase. Clearing the
    /// monitor and session identity together makes retained monitor callbacks
    /// inert after a structural invalidation.
    func reset() {
        invalidateNativeTracking()
        phase = .idle
    }

    private func currentTranslation() -> CGSize {
        let current = NSEvent.mouseLocation
        return CGSize(width: current.x - anchorScreenPoint.x, height: -(current.y - anchorScreenPoint.y))
    }

    private func invalidateNativeTracking() {
        if let monitor { removeLocalMonitor(monitor) }
        monitor = nil
        sessionID = nil
        anchorScreenPoint = .zero
    }

    deinit {
        if let monitor { removeLocalMonitor(monitor) }
    }
}
