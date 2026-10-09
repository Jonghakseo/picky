//
//  PickyHubPresentationDisplayPolicy.swift
//  Picky
//
//  Chooses the display that receives the Hub window. The Hub is an ordinary
//  workspace window, so it cannot join another app's full-screen Space. When
//  the requested display is showing one, AppKit parks the window on some other
//  display and clamps a frame computed for the original display into that
//  screen's corner. Picking a display with a normal Space up front lets the
//  controller center the window where it will actually appear.
//

import AppKit
import CoreGraphics

struct PickyHubDisplayCandidate: Equatable {
    let displayID: CGDirectDisplayID
    /// Global CoreGraphics coordinates (top-left origin), matching
    /// `kCGWindowBounds`.
    let bounds: CGRect
}

enum PickyHubPresentationDisplayPolicy {
    /// - Parameters:
    ///   - requested: The display the user summoned the Hub from.
    ///   - currentWindowDisplay: The display the Hub window last lived on.
    ///   - displays: Connected displays in `NSScreen.screens` order.
    ///   - externalWindowFrames: On-screen, layer-0 windows owned by other apps.
    static func destination(
        requested: CGDirectDisplayID?,
        currentWindowDisplay: CGDirectDisplayID?,
        displays: [PickyHubDisplayCandidate],
        externalWindowFrames: [CGRect]
    ) -> CGDirectDisplayID? {
        guard let requested else { return nil }
        let fullScreen = fullScreenDisplayIDs(displays: displays, externalWindowFrames: externalWindowFrames)
        guard fullScreen.contains(requested) else { return requested }
        let normal = displays.map(\.displayID).filter { !fullScreen.contains($0) }
        if let currentWindowDisplay, normal.contains(currentWindowDisplay) {
            return currentWindowDisplay
        }
        // Every display showing full screen leaves no better choice.
        return normal.first ?? requested
    }

    /// A display shows a full-screen Space when another app's normal-layer
    /// window covers its whole bounds, menu bar area included. Zoomed windows
    /// stop below the menu bar, so they do not qualify.
    static func fullScreenDisplayIDs(
        displays: [PickyHubDisplayCandidate],
        externalWindowFrames: [CGRect]
    ) -> Set<CGDirectDisplayID> {
        Set(displays.compactMap { display in
            externalWindowFrames.contains { covers($0, display.bounds) } ? display.displayID : nil
        })
    }

    private static func covers(_ window: CGRect, _ display: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(window.minX - display.minX) <= tolerance
            && abs(window.minY - display.minY) <= tolerance
            && abs(window.width - display.width) <= tolerance
            && abs(window.height - display.height) <= tolerance
    }
}

@MainActor
enum PickyHubDisplaySnapshot {
    static func displays() -> [PickyHubDisplayCandidate] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.pickyDisplayID else { return nil }
            return PickyHubDisplayCandidate(displayID: id, bounds: CGDisplayBounds(id))
        }
    }

    /// Window bounds do not require Screen Recording permission; only titles do.
    static func externalWindowFrames() -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return nil
            }
            return frame
        }
    }
}
