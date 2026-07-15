//
//  PickyHUDTypography.swift
//  Picky
//
//  Typography tokens for the Pickle HUD. These intentionally apply only to
//  readable text, not decorative SF Symbols or tiny state glyphs such as pin icons.
//
//  Sizes are dynamic: each base constant is multiplied by the live global app
//  font scale (`PickyAppFontScaleStore`) so the entire HUD/Conversation surface
//  flips together when the user hits ⌘+ / ⌘- / ⌘0. SwiftUI re-rendering still
//  flows through the `@EnvironmentObject`/`@Environment(\.pickyAppFontScale)`
//  injected at every NSPanel hosting root; the static accessors below just
//  read the latest cached value at body-evaluation time.
//

import SwiftUI

enum PickyHUDTypography {
    /// Live multiplier for typography tokens. Mirrors `PickyAppFontScaleStore.staticScale`
    /// so a SwiftUI view re-evaluating its `body` picks up the latest scale on the
    /// same render pass that the store published.
    private static var scale: CGFloat { PickyAppFontScaleStore.staticCGScale }

    enum Size {
        static var title: CGFloat { 14 * scale }
        static var heading1: CGFloat { 15 * scale }
        static var heading2: CGFloat { 14 * scale }
        static var heading3: CGFloat { 13.5 * scale }
        static var body: CGFloat { 13 * scale }
        static var bodyCompact: CGFloat { 12.5 * scale }
        static var supporting: CGFloat { 12 * scale }
        static var label: CGFloat { 11.5 * scale }
        static var status: CGFloat { 11 * scale }
        static var meta: CGFloat { 10.5 * scale }
        static var minimumText: CGFloat { 10 * scale }
        static var badge: CGFloat { 8 * scale }
        static var badgeIcon: CGFloat { 7 * scale }
    }

    static var title: Font { .system(size: Size.title, weight: .semibold) }

    static func heading(level: Int) -> Font {
        switch level {
        case 1: return .system(size: Size.heading1, weight: .semibold)
        case 2: return .system(size: Size.heading2, weight: .semibold)
        default: return .system(size: Size.heading3, weight: .semibold)
        }
    }

    static var body: Font { .system(size: Size.body, weight: .regular) }
    static var bodyMedium: Font { .system(size: Size.body, weight: .medium) }
    static var bodySemibold: Font { .system(size: Size.body, weight: .semibold) }

    static var bodyCompact: Font { .system(size: Size.bodyCompact, weight: .regular) }
    static var bodyCompactMedium: Font { .system(size: Size.bodyCompact, weight: .medium) }
    static var bodyCompactSemibold: Font { .system(size: Size.bodyCompact, weight: .semibold) }
    static var bodyCompactMonospaced: Font { .system(size: Size.bodyCompact, weight: .regular, design: .monospaced) }

    static var supporting: Font { .system(size: Size.supporting, weight: .regular) }
    static var supportingMedium: Font { .system(size: Size.supporting, weight: .medium) }
    static var supportingSemibold: Font { .system(size: Size.supporting, weight: .semibold) }
    static var supportingMonospaced: Font { .system(size: Size.supporting, weight: .regular, design: .monospaced) }
    static var supportingMonospacedMedium: Font { .system(size: Size.supporting, weight: .medium, design: .monospaced) }
    static var supportingMonospacedSemibold: Font { .system(size: Size.supporting, weight: .semibold, design: .monospaced) }

    static var labelMedium: Font { .system(size: Size.label, weight: .medium) }
    static var labelSemibold: Font { .system(size: Size.label, weight: .semibold) }
    static var labelBold: Font { .system(size: Size.label, weight: .bold) }
    static var labelMonospacedMedium: Font { .system(size: Size.label, weight: .medium, design: .monospaced) }
    static var labelMonospacedSemibold: Font { .system(size: Size.label, weight: .semibold, design: .monospaced) }

    static var status: Font { .system(size: Size.status, weight: .regular) }
    static var statusSemibold: Font { .system(size: Size.status, weight: .semibold) }
    static var statusMedium: Font { .system(size: Size.status, weight: .medium) }
    static var statusMonospacedMedium: Font { .system(size: Size.status, weight: .medium, design: .monospaced) }

    static var meta: Font { .system(size: Size.meta, weight: .regular) }
    static var metaMedium: Font { .system(size: Size.meta, weight: .medium) }
    static var metaSemibold: Font { .system(size: Size.meta, weight: .semibold) }
    static var metaBold: Font { .system(size: Size.meta, weight: .bold) }
    static var metaMonospacedMedium: Font { .system(size: Size.meta, weight: .medium, design: .monospaced) }
    static var metaMonospacedSemibold: Font { .system(size: Size.meta, weight: .semibold, design: .monospaced) }

    static var minimum: Font { .system(size: Size.minimumText, weight: .regular) }
    static var minimumMedium: Font { .system(size: Size.minimumText, weight: .medium) }
    static var minimumSemibold: Font { .system(size: Size.minimumText, weight: .semibold) }
    static var minimumBold: Font { .system(size: Size.minimumText, weight: .bold) }
    static var minimumMonospacedMedium: Font { .system(size: Size.minimumText, weight: .medium, design: .monospaced) }
    static var minimumMonospaced: Font { .system(size: Size.minimumText, weight: .regular, design: .monospaced) }
    static var minimumMonospacedBold: Font { .system(size: Size.minimumText, weight: .bold, design: .monospaced) }

    static var badgeSemibold: Font { .system(size: Size.badge, weight: .semibold) }
    static var badgeBold: Font { .system(size: Size.badge, weight: .bold) }
    static var badgeBoldRounded: Font { .system(size: Size.badge, weight: .bold, design: .rounded) }
    static var badgeMonospacedBold: Font { .system(size: Size.badge, weight: .bold, design: .monospaced) }
    static var badgeIconBold: Font { .system(size: Size.badgeIcon, weight: .bold) }
}
