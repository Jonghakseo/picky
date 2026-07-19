//
//  PickyPendingInkCaptureStore.swift
//  Picky
//

import Foundation

/// Keeps an ink capture attached to its input until the matching neutral
/// context packet is assembled. Voice and text submissions share this input-ID
/// lifecycle so a stale input cannot consume a later mark.
@MainActor
final class PickyPendingInkCaptureStore {
    private var captures: [UUID: PickyInkCapture] = [:]

    func store(_ capture: PickyInkCapture, for inputID: UUID) {
        captures[inputID] = capture
    }

    func consume(for inputID: UUID) -> PickyInkCapture? {
        captures.removeValue(forKey: inputID)
    }
}
