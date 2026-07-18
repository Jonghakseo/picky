//
//  PickyHUDDockReorderDragController.swift
//  Picky
//
//  AppKit event monitor that keeps a dock reorder alive while SwiftUI reparents
//  the dragged icon across group boundaries.
//

import AppKit
import Combine

final class PickyDockReorderDragController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case dragging(sessionID: String, translation: CGSize)
        case ended(sessionID: String, translation: CGSize)
    }

    @Published private(set) var phase: Phase = .idle

    private var monitor: Any?
    private var anchorScreenPoint: NSPoint = .zero
    private var sessionID: String?

    func begin(sessionID: String, anchorScreenPoint: NSPoint) {
        if self.sessionID != nil { cancelMonitor() }
        self.sessionID = sessionID
        self.anchorScreenPoint = anchorScreenPoint
        phase = .dragging(sessionID: sessionID, translation: currentTranslation())
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let sessionID = self.sessionID else { return event }
            let translation = self.currentTranslation()
            switch event.type {
            case .leftMouseUp:
                self.phase = .ended(sessionID: sessionID, translation: translation)
                self.cancelMonitor()
                self.sessionID = nil
                return nil
            default:
                self.phase = .dragging(sessionID: sessionID, translation: translation)
                return nil
            }
        }
    }

    func reset() {
        phase = .idle
    }

    private func currentTranslation() -> CGSize {
        let current = NSEvent.mouseLocation
        return CGSize(width: current.x - anchorScreenPoint.x, height: -(current.y - anchorScreenPoint.y))
    }

    private func cancelMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { cancelMonitor() }
}
