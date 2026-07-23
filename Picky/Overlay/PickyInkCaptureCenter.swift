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
    /// Starts a new capture while keeping visible strokes from a failed prior
    /// text submission in the live overlay and final result. The default keeps
    /// existing lightweight coordinators source-compatible.
    @discardableResult
    func begin(
        source: PickyInkCaptureSource,
        origin: CGPoint,
        priorCapture: PickyInkCapture?
    ) -> Bool
    func finish(warpSystemCursor: Bool) -> PickyInkCapture?
    func cancel()

    /// Pre-installs the shared suppressing event tap ahead of the first draw.
    /// Default is a no-op so lightweight test doubles need not implement it.
    @discardableResult
    func ensureEventTapInstalled() -> Bool
    /// Removes the shared tap entirely (permission loss / app stop).
    func teardownEventTap()
}

extension PickyInkCaptureCoordinating {
    @discardableResult
    func begin(
        source: PickyInkCaptureSource,
        origin: CGPoint,
        priorCapture: PickyInkCapture?
    ) -> Bool {
        begin(source: source, origin: origin)
    }

    @discardableResult
    func begin(source: PickyInkCaptureSource) -> Bool {
        begin(source: source, origin: NSEvent.mouseLocation)
    }

    func finish() -> PickyInkCapture? {
        finish(warpSystemCursor: false)
    }

    @discardableResult
    func ensureEventTapInstalled() -> Bool { false }
    func teardownEventTap() {}
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

    @discardableResult
    func begin(
        source: PickyInkCaptureSource,
        origin: CGPoint = NSEvent.mouseLocation,
        priorCapture: PickyInkCapture?
    ) -> Bool {
        controller.begin(source: source, origin: origin, priorCapture: priorCapture)
    }

    func finish(warpSystemCursor: Bool = false) -> PickyInkCapture? {
        controller.finish(warpSystemCursor: warpSystemCursor)
    }

    func cancel() {
        controller.cancel()
    }

    @discardableResult
    func ensureEventTapInstalled() -> Bool {
        controller.ensureEventTapInstalled()
    }

    func teardownEventTap() {
        controller.teardownEventTap()
    }
}
