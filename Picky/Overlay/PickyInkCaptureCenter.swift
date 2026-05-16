//
//  PickyInkCaptureCenter.swift
//  Picky
//
//  Shared ink-capture coordinator for the always-on Picky input flow.
//  Pickle targeting can reuse the same captured screen marks without spinning
//  up a second low-level event tap.
//

import AppKit
import CoreGraphics
import Foundation

protocol PickyInkCaptureCoordinating: AnyObject {
    var isActive: Bool { get }
    var onStateChange: (PickyInkOverlayState) -> Void { get set }
    var shouldPassThroughMouseEvent: (_ point: CGPoint, _ source: PickyInkCaptureSource) -> Bool { get set }

    @discardableResult
    func begin(source: PickyInkCaptureSource, origin: CGPoint) -> Bool
    func finish(warpSystemCursor: Bool) -> PickyInkCapture?
    func cancel()
}

extension PickyInkCaptureCoordinating {
    @discardableResult
    func begin(source: PickyInkCaptureSource) -> Bool {
        begin(source: source, origin: NSEvent.mouseLocation)
    }

    func finish() -> PickyInkCapture? {
        finish(warpSystemCursor: false)
    }
}

final class PickyInkCaptureCenter: PickyInkCaptureCoordinating {
    static let shared = PickyInkCaptureCenter()

    var onStateChange: (PickyInkOverlayState) -> Void = { _ in }
    var shouldPassThroughMouseEvent: (_ point: CGPoint, _ source: PickyInkCaptureSource) -> Bool = { _, _ in false }

    var isActive: Bool { controller.isActive }

    private let controller: PickyInkCaptureController

    init(controller: PickyInkCaptureController = PickyInkCaptureController()) {
        self.controller = controller
        controller.onStateChange = { [weak self] state in
            self?.onStateChange(state)
        }
        controller.shouldPassThroughMouseEvent = { [weak self] point, source in
            self?.shouldPassThroughMouseEvent(point, source) ?? false
        }
    }

    @discardableResult
    func begin(source: PickyInkCaptureSource, origin: CGPoint = NSEvent.mouseLocation) -> Bool {
        controller.begin(source: source, origin: origin)
    }

    func finish(warpSystemCursor: Bool = false) -> PickyInkCapture? {
        controller.finish(warpSystemCursor: warpSystemCursor)
    }

    func cancel() {
        controller.cancel()
    }
}
