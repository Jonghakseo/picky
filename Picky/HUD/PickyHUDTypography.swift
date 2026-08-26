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

import AppKit
import SwiftUI

enum PickyHUDTypography {
    /// Live multiplier for typography tokens. Mirrors `PickyAppFontScaleStore.staticScale`
    /// so a SwiftUI view re-evaluating its `body` picks up the latest scale on the
    /// same render pass that the store published.
    private static var scale: CGFloat { PickyAppFontScaleStore.staticCGScale }

    private enum BaseSize {
        static let body: CGFloat = 13
        static let label: CGFloat = 11.5
        static let meta: CGFloat = 10.5
        static let minimum: CGFloat = 10
        static let badge: CGFloat = 8
    }

    enum Size {
        static var title: CGFloat { 14 * scale }
        // Markdown heading ladder. Previously 15/14/13.5 against a 13pt body,
        // which is a 1.08x step at h2 — too small to register as hierarchy, so
        // headings had to rely entirely on weight. Widened to a ~1.15x step so
        // a section break is legible while scrolling.
        static var heading1: CGFloat { 17 * scale }
        static var heading2: CGFloat { 15.5 * scale }
        static var heading3: CGFloat { 14 * scale }
        static var body: CGFloat { BaseSize.body * scale }
        static var bodyCompact: CGFloat { 12.5 * scale }
        static var supporting: CGFloat { 12 * scale }
        static var label: CGFloat { BaseSize.label * scale }
        static var status: CGFloat { 11 * scale }
        static var meta: CGFloat { BaseSize.meta * scale }
        static var minimumText: CGFloat { BaseSize.minimum * scale }
        static var badge: CGFloat { BaseSize.badge * scale }
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

    /// AppKit counterpart for geometry that must reserve the body role's
    /// measured line height before SwiftUI renders it.
    static func bodyNSFont(fontScale: CGFloat) -> NSFont {
        .systemFont(ofSize: BaseSize.body * max(0, fontScale), weight: .regular)
    }

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

    /// Quiet identity for a dock folder. It deliberately shares the compact
    /// control-label scale while keeping its semantic purpose distinct from
    /// metadata and badges.
    static var dockGroupIdentity: Font { labelSemibold }

    /// AppKit counterpart for the dock-group identity role. Layout reserves
    /// this exact font's line height before SwiftUI renders its label.
    static func dockGroupIdentityNSFont(fontScale: CGFloat) -> NSFont {
        labelSemiboldNSFont(fontScale: fontScale)
    }

    /// AppKit counterpart for width checks that share the label role with a
    /// SwiftUI surface.
    static func labelSemiboldNSFont(fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale) -> NSFont {
        .systemFont(ofSize: BaseSize.label * max(0, fontScale), weight: .semibold)
    }
    static var labelMonospacedMedium: Font { .system(size: Size.label, weight: .medium, design: .monospaced) }
    static var labelMonospacedSemibold: Font { .system(size: Size.label, weight: .semibold, design: .monospaced) }

    static var status: Font { .system(size: Size.status, weight: .regular) }
    static var statusSemibold: Font { .system(size: Size.status, weight: .semibold) }
    static var statusMedium: Font { .system(size: Size.status, weight: .medium) }
    static var statusMonospacedMedium: Font { .system(size: Size.status, weight: .medium, design: .monospaced) }

    static var meta: Font { .system(size: Size.meta, weight: .regular) }
    static var metaMedium: Font { .system(size: Size.meta, weight: .medium) }

    /// AppKit counterpart for geometry that must reserve the meta role's
    /// measured line height before SwiftUI renders it.
    static func metaNSFont(fontScale: CGFloat) -> NSFont {
        .systemFont(ofSize: BaseSize.meta * max(0, fontScale), weight: .regular)
    }
    static var metaSemibold: Font { .system(size: Size.meta, weight: .semibold) }
    static var metaBold: Font { .system(size: Size.meta, weight: .bold) }
    static var metaMonospacedMedium: Font { .system(size: Size.meta, weight: .medium, design: .monospaced) }
    static var metaMonospacedSemibold: Font { .system(size: Size.meta, weight: .semibold, design: .monospaced) }

    static var minimum: Font { .system(size: Size.minimumText, weight: .regular) }

    /// AppKit counterpart for measurements that use the minimum metadata role.
    static func minimumNSFont(fontScale: CGFloat) -> NSFont {
        .systemFont(ofSize: BaseSize.minimum * max(0, fontScale), weight: .regular)
    }

    static var minimumMedium: Font { .system(size: Size.minimumText, weight: .medium) }
    static var minimumSemibold: Font { .system(size: Size.minimumText, weight: .semibold) }
    static var minimumBold: Font { .system(size: Size.minimumText, weight: .bold) }
    static var minimumMonospacedMedium: Font { .system(size: Size.minimumText, weight: .medium, design: .monospaced) }
    static var minimumMonospaced: Font { .system(size: Size.minimumText, weight: .regular, design: .monospaced) }
    static var minimumMonospacedBold: Font { .system(size: Size.minimumText, weight: .bold, design: .monospaced) }

    static var badgeSemibold: Font { .system(size: Size.badge, weight: .semibold) }
    static var badgeBold: Font { .system(size: Size.badge, weight: .bold) }

    /// AppKit counterpart for compact shortcut-hint column measurements.
    static func badgeSemiboldNSFont(fontScale: CGFloat) -> NSFont {
        .systemFont(ofSize: BaseSize.badge * max(0, fontScale), weight: .semibold)
    }
    static var badgeBoldRounded: Font { .system(size: Size.badge, weight: .bold, design: .rounded) }
    static var badgeMonospacedBold: Font { .system(size: Size.badge, weight: .bold, design: .monospaced) }
    static var badgeIconBold: Font { .system(size: Size.badgeIcon, weight: .bold) }
}
