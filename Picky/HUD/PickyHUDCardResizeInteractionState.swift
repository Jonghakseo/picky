//
//  PickyHUDCardResizeInteractionState.swift
//  Picky
//
//  Pure interaction state for the HUD card resize handle.
//

struct PickyHUDCardResizeInteractionState: Equatable {
    private(set) var isHovered = false
    private(set) var isDragging = false

    var isVisible: Bool { isHovered || isDragging }

    mutating func setHovered(_ hovering: Bool) {
        isHovered = hovering
    }

    mutating func beginDragging() {
        isDragging = true
    }

    @discardableResult
    mutating func endDragging() -> Bool {
        let wasDragging = isDragging
        isDragging = false
        return wasDragging
    }

    @discardableResult
    mutating func reset() -> Bool {
        let wasDragging = isDragging
        isHovered = false
        isDragging = false
        return wasDragging
    }
}
