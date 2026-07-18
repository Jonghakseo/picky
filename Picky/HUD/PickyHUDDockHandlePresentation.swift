//
//  PickyHUDDockHandlePresentation.swift
//  Picky
//
//  Appearance-aware visual projection for the HUD dock drag handle.
//

import SwiftUI

struct PickyHUDDockHandlePresentation {
    let foregroundColor: Color
    let opacity: Double

    static func resolve(isActive: Bool) -> Self {
        Self(
            foregroundColor: DS.Colors.textPrimary,
            opacity: isActive ? 0.90 : 0.72
        )
    }
}
