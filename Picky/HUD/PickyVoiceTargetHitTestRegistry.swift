//
//  PickyVoiceTargetHitTestRegistry.swift
//  Picky
//
//  Resolves the visible Pickle conversation card under a screen-space point.
//

import AppKit
import SwiftUI

@MainActor
protocol PickyVoiceTargetResolving: AnyObject {
    func sessionID(at screenPoint: CGPoint) -> String?
}

struct PickyVoiceTargetHitCandidate: Equatable {
    let sessionID: String
    let screenFrame: CGRect
    /// Lower values are closer to the front, matching `NSApplication.orderedWindows`.
    let windowOrder: Int
    let windowNumber: Int

    init(
        sessionID: String,
        screenFrame: CGRect,
        windowOrder: Int,
        windowNumber: Int = 0
    ) {
        self.sessionID = sessionID
        self.screenFrame = screenFrame
        self.windowOrder = windowOrder
        self.windowNumber = windowNumber
    }
}

enum PickyVoiceTargetHitTestPolicy {
    static func sessionID(
        at screenPoint: CGPoint,
        candidates: [PickyVoiceTargetHitCandidate]
    ) -> String? {
        candidates
            .filter { $0.screenFrame.contains(screenPoint) }
            .min { lhs, rhs in
                if lhs.windowOrder != rhs.windowOrder {
                    return lhs.windowOrder < rhs.windowOrder
                }
                return lhs.sessionID < rhs.sessionID
            }?
            .sessionID
    }
}

@MainActor
protocol PickyVoiceTargetHitRegionProviding: AnyObject {
    var voiceTargetHitCandidate: PickyVoiceTargetHitCandidate? { get }
}

@MainActor
final class PickyVoiceTargetHitTestRegistry: PickyVoiceTargetResolving {
    private final class WeakRegion {
        weak var value: AnyObject?

        init(_ value: any PickyVoiceTargetHitRegionProviding) {
            self.value = value
        }

        var region: (any PickyVoiceTargetHitRegionProviding)? {
            value as? any PickyVoiceTargetHitRegionProviding
        }
    }

    private var regions: [ObjectIdentifier: WeakRegion] = [:]
    private let frontmostWindowNumberProvider: @MainActor (CGPoint) -> Int

    init(
        frontmostWindowNumberProvider: @escaping @MainActor (CGPoint) -> Int = {
            NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0)
        }
    ) {
        self.frontmostWindowNumberProvider = frontmostWindowNumberProvider
    }

    func register(_ region: any PickyVoiceTargetHitRegionProviding) {
        regions[ObjectIdentifier(region)] = WeakRegion(region)
    }

    func unregister(_ region: any PickyVoiceTargetHitRegionProviding) {
        regions.removeValue(forKey: ObjectIdentifier(region))
    }

    func sessionID(at screenPoint: CGPoint) -> String? {
        regions = regions.filter { $0.value.region != nil }
        let frontmostWindowNumber = frontmostWindowNumberProvider(screenPoint)
        let candidates = regions.values
            .compactMap { $0.region?.voiceTargetHitCandidate }
            .filter { $0.windowNumber == frontmostWindowNumber }
        return PickyVoiceTargetHitTestPolicy.sessionID(at: screenPoint, candidates: candidates)
    }
}

struct PickyVoiceTargetHitRegionHost: NSViewRepresentable {
    let sessionID: String
    let isEligible: Bool
    let registry: PickyVoiceTargetHitTestRegistry

    func makeNSView(context: Context) -> PickyVoiceTargetHitRegionNSView {
        let view = PickyVoiceTargetHitRegionNSView()
        view.registry = registry
        apply(to: view)
        registry.register(view)
        return view
    }

    func updateNSView(_ nsView: PickyVoiceTargetHitRegionNSView, context: Context) {
        apply(to: nsView)
    }

    static func dismantleNSView(_ nsView: PickyVoiceTargetHitRegionNSView, coordinator: Void) {
        nsView.registry?.unregister(nsView)
        nsView.registry = nil
    }

    private func apply(to view: PickyVoiceTargetHitRegionNSView) {
        view.sessionID = sessionID
        view.isVoiceTargetEligible = isEligible
    }
}

@MainActor
final class PickyVoiceTargetHitRegionNSView: NSView, PickyVoiceTargetHitRegionProviding {
    weak var registry: PickyVoiceTargetHitTestRegistry?
    var sessionID = ""
    var isVoiceTargetEligible = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    var voiceTargetHitCandidate: PickyVoiceTargetHitCandidate? {
        guard isVoiceTargetEligible,
              !sessionID.isEmpty,
              let window,
              window.isVisible,
              !bounds.isEmpty,
              !isHiddenOrTransparentInViewHierarchy
        else { return nil }

        let visibleBounds = visibleRect.intersection(bounds)
        guard !visibleBounds.isEmpty else { return nil }
        let windowFrame = convert(visibleBounds, to: nil)
        let screenFrame = window.convertToScreen(windowFrame)
        guard !screenFrame.isEmpty else { return nil }
        let windowOrder = NSApp.orderedWindows.firstIndex(where: { $0 === window }) ?? Int.max
        return PickyVoiceTargetHitCandidate(
            sessionID: sessionID,
            screenFrame: screenFrame,
            windowOrder: windowOrder,
            windowNumber: window.windowNumber
        )
    }

    private var isHiddenOrTransparentInViewHierarchy: Bool {
        var view: NSView? = self
        while let current = view {
            if current.isHidden || current.alphaValue <= 0.01 { return true }
            view = current.superview
        }
        return false
    }
}
