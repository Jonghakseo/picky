//
//  PickyHUDDockReorderDragController.swift
//  Picky
//
//  AppKit event monitor that keeps a dock reorder alive while SwiftUI moves
//  the dragged row across group boundaries.
//

import AppKit
import Combine

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
        // Install the monitor before publishing the pickup. A geometry-rejected
        // pickup can synchronously reset this controller, which must remove the
        // monitor rather than leaving it alive after the failed handoff.
        phase = .dragging(sessionID: sessionID, translation: currentTranslation())
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
