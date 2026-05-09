//
//  PickyHUDTypography.swift
//  Picky
//
//  Typography tokens for the Pickle HUD. These intentionally apply only to
//  readable text, not decorative SF Symbols or tiny state glyphs such as pin icons.
//

import SwiftUI

enum PickyHUDTypography {
    enum Size {
        static let title: CGFloat = 14
        static let heading1: CGFloat = 15
        static let heading2: CGFloat = 14
        static let heading3: CGFloat = 13.5
        static let body: CGFloat = 13
        static let bodyCompact: CGFloat = 12.5
        static let supporting: CGFloat = 12
        static let label: CGFloat = 11.5
        static let status: CGFloat = 11
        static let meta: CGFloat = 10.5
        static let minimumText: CGFloat = 10
    }

    static let title = Font.system(size: Size.title, weight: .semibold)

    static func heading(level: Int) -> Font {
        switch level {
        case 1: return .system(size: Size.heading1, weight: .semibold)
        case 2: return .system(size: Size.heading2, weight: .semibold)
        default: return .system(size: Size.heading3, weight: .semibold)
        }
    }

    static let body = Font.system(size: Size.body, weight: .regular)
    static let bodyMedium = Font.system(size: Size.body, weight: .medium)
    static let bodySemibold = Font.system(size: Size.body, weight: .semibold)

    static let bodyCompact = Font.system(size: Size.bodyCompact, weight: .regular)
    static let bodyCompactMedium = Font.system(size: Size.bodyCompact, weight: .medium)
    static let bodyCompactSemibold = Font.system(size: Size.bodyCompact, weight: .semibold)

    static let supporting = Font.system(size: Size.supporting, weight: .regular)
    static let supportingMedium = Font.system(size: Size.supporting, weight: .medium)
    static let supportingSemibold = Font.system(size: Size.supporting, weight: .semibold)
    static let supportingMonospaced = Font.system(size: Size.supporting, weight: .regular, design: .monospaced)
    static let supportingMonospacedMedium = Font.system(size: Size.supporting, weight: .medium, design: .monospaced)
    static let supportingMonospacedSemibold = Font.system(size: Size.supporting, weight: .semibold, design: .monospaced)

    static let labelMedium = Font.system(size: Size.label, weight: .medium)
    static let labelSemibold = Font.system(size: Size.label, weight: .semibold)
    static let labelBold = Font.system(size: Size.label, weight: .bold)
    static let labelMonospacedMedium = Font.system(size: Size.label, weight: .medium, design: .monospaced)
    static let labelMonospacedSemibold = Font.system(size: Size.label, weight: .semibold, design: .monospaced)

    static let status = Font.system(size: Size.status, weight: .regular)
    static let statusSemibold = Font.system(size: Size.status, weight: .semibold)
    static let statusMedium = Font.system(size: Size.status, weight: .medium)
    static let statusMonospacedMedium = Font.system(size: Size.status, weight: .medium, design: .monospaced)

    static let meta = Font.system(size: Size.meta, weight: .regular)
    static let metaMedium = Font.system(size: Size.meta, weight: .medium)
    static let metaSemibold = Font.system(size: Size.meta, weight: .semibold)
    static let metaBold = Font.system(size: Size.meta, weight: .bold)
    static let metaMonospacedMedium = Font.system(size: Size.meta, weight: .medium, design: .monospaced)
    static let metaMonospacedSemibold = Font.system(size: Size.meta, weight: .semibold, design: .monospaced)

    static let minimum = Font.system(size: Size.minimumText, weight: .regular)
    static let minimumMedium = Font.system(size: Size.minimumText, weight: .medium)
    static let minimumSemibold = Font.system(size: Size.minimumText, weight: .semibold)
    static let minimumBold = Font.system(size: Size.minimumText, weight: .bold)
    static let minimumMonospacedMedium = Font.system(size: Size.minimumText, weight: .medium, design: .monospaced)
    static let minimumMonospacedBold = Font.system(size: Size.minimumText, weight: .bold, design: .monospaced)
}
