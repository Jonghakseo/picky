//
//  PickyHUDDockResizeTabPlacement.swift
//  Picky
//
//  Where the dock's resize tab sits. The tab lives on the dock's free edge,
//  the side facing the screen interior where the conversation card opens.
//

import SwiftUI

enum PickyHUDDockResizeTabPlacement {
    static func alignment(for dockSide: PickyHUDDockSide) -> Alignment {
        switch dockSide {
        case .right: .leading
        case .left: .trailing
        case .bottom: .top
        case .top: .bottom
        }
    }

    /// Pushes the tab out past the rail so it overlaps the edge by half a point.
    static func offset(for dockSide: PickyHUDDockSide, metrics: PickyHUDDockMetrics) -> CGSize {
        let depth = metrics.resizeTabDepth - 0.5
        switch dockSide {
        case .right: return CGSize(width: -depth, height: 0)
        case .left: return CGSize(width: depth, height: 0)
        case .bottom: return CGSize(width: 0, height: -depth)
        case .top: return CGSize(width: 0, height: depth)
        }
    }
}
