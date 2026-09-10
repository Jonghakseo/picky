//
//  PickyHubTheme.swift
//  Picky
//
//  Visual tokens for the hub window. The mockup (`docs/new-interface/mockups`)
//  is the source of truth for the light palette; dark values are derived so
//  the same roles keep their contrast relationships. Everything else in the
//  hub should read from here (or from `DS`) rather than inlining raw values.
//

import SwiftUI

enum PickyHubTheme {
    enum Colors {
        /// Action Blue for CTA fills, links, and selection. Mockup `--blue`.
        static let action = Color(light: Color(hex: "#5284FF"), dark: Color(hex: "#6699FF"))
        static let actionHover = Color(light: Color(hex: "#3D73F5"), dark: Color(hex: "#7FA8FF"))
        /// Very light tint used behind hovered outline buttons and links.
        static let actionTint = Color(light: Color(hex: "#F7F9FF"), dark: Color(hex: "#1C2233"))
        static let brand = Color(hex: "#6699FF")

        /// Window canvas. Mockup `--white`.
        static let canvas = Color(light: Color(hex: "#FFFFFF"), dark: Color(hex: "#151719"))
        /// Sidebar and card fill. Mockup `--cool-gray`.
        static let surface = Color(light: Color(hex: "#F9FAFF"), dark: Color(hex: "#1C1F24"))
        /// Active/hovered navigation row fill.
        static let navHighlight = Color(light: Color(hex: "#F1F2FB"), dark: Color(hex: "#262A31"))
        /// Elevated surface inside modals.
        static let modal = Color(light: Color(hex: "#FFFFFF"), dark: Color(hex: "#1F2227"))
        static let modalBackdrop = Color(hex: "#131419").opacity(0.52)

        static let border = Color(light: Color(hex: "#DCDFE6"), dark: Color(hex: "#2F343B"))
        static let borderSoft = Color(light: Color(hex: "#EAEBF0"), dark: Color(hex: "#272B31"))

        /// Mockup `--ink`.
        static let textPrimary = Color(light: Color(hex: "#131419"), dark: Color(hex: "#F1F2F4"))
        static let textSecondary = Color(light: Color(hex: "#404040"), dark: Color(hex: "#C5C9CF"))
        static let textTertiary = Color(light: Color(hex: "#808080"), dark: Color(hex: "#8E949C"))
        /// Placeholder thumbnails and disabled fills. Mockup `--muted`.
        static let muted = Color(light: Color(hex: "#8D8D97"), dark: Color(hex: "#4B515A"))
        static let textOnAction: Color = .white

        static let success = Color(light: Color(hex: "#108D6F"), dark: Color(hex: "#4CD6A9"))
        static let successBackground = Color(light: Color(hex: "#D7EEE4"), dark: Color(hex: "#123A30"))
        /// Foreground-grade semantic red keeps destructive settings readable in light appearance.
        static let danger = DS.Colors.destructiveText
        static let dangerTint = Color(light: Color(hex: "#FFF8F8"), dark: Color(hex: "#33201F"))
        static let warning = DS.Colors.warningText

        /// Neutral pill used for installed badges and neutral status chips.
        static let badgeText = Color(light: Color(hex: "#595959"), dark: Color(hex: "#B8BDC4"))
        /// Chart bar track.
        static let barTrack = Color(light: Color(hex: "#E6E9F2"), dark: Color(hex: "#2B3038"))
        /// X brand button fill.
        static let xBrand = Color(light: Color(hex: "#131419"), dark: Color(hex: "#F1F2F4"))
        static let xBrandForeground = Color(light: .white, dark: Color(hex: "#131419"))
        static let linkedInBrand = Color(hex: "#0A79B9")
    }

    enum Typography {
        /// Section title (24/750, -1 tracking).
        static let sectionTitle: CGFloat = 24
        static let pageTitle: CGFloat = 24
        static let cardTitle: CGFloat = 21
        static let greetingTitle: CGFloat = 18
        static let modalTitle: CGFloat = 20
        static let body: CGFloat = 14
        static let bodySmall: CGFloat = 13
        static let caption: CGFloat = 12
        static let nav: CGFloat = 14
    }

    enum Layout {
        static let sidebarWidth: CGFloat = 190
        static let minimumWindowSize = CGSize(width: 760, height: 560)
        static let defaultWindowSize = CGSize(width: 1020, height: 720)
        /// Main column measure. Content is centered and never wider than this.
        static let contentMaxWidth: CGFloat = 780
        static let contentHorizontalPadding: CGFloat = 30
        static let contentTopPadding: CGFloat = 32
        static let contentBottomPadding: CGFloat = 60
        static let sectionSpacing: CGFloat = 42
        static let sectionHeadingBottom: CGFloat = 15
        /// Card grid breakpoints measured against the main column width.
        static let threeColumnMinWidth: CGFloat = 640
        static let twoColumnMinWidth: CGFloat = 460
        static let cardMinWidth: CGFloat = 280
        static let cardGap: CGFloat = 10
        static let quickGap: CGFloat = 12
        static let navRowMinHeight: CGFloat = 40
        static let trafficLightsInset = CGPoint(x: 16, y: 20)
    }

    enum Radius {
        static let card: CGFloat = 12
        static let cardCompact: CGFloat = 10
        static let nav: CGFloat = 9
        static let control: CGFloat = 8
        static let modal: CGFloat = 16
        static let pill: CGFloat = 999
        static let window: CGFloat = 18
    }

    enum Shadow {
        static let subtleColor = Color(hex: "#191B26").opacity(0.045)
        static let subtleRadius: CGFloat = 12
        static let subtleY: CGFloat = 8
        static let floatingColor = Color(hex: "#191B26").opacity(0.12)
        static let floatingRadius: CGFloat = 6
        static let floatingY: CGFloat = 4
        static let modalColor = Color(hex: "#131419").opacity(0.28)
        static let modalRadius: CGFloat = 32
        static let modalY: CGFloat = 24
    }

    enum Motion {
        static let hover = SwiftUI.Animation.easeOut(duration: DS.Animation.fast)
        static let page = SwiftUI.Animation.easeOut(duration: 0.16)
        static let modal = SwiftUI.Animation.spring(response: 0.26, dampingFraction: 0.9)
    }

    /// Focus ring used on custom controls: 3pt Action Blue at 45%, 3pt offset.
    static let focusRingColor = Colors.action.opacity(0.45)
    static let focusRingWidth: CGFloat = 3
    static let focusRingOffset: CGFloat = 3
}

extension View {
    /// Mockup `:focus-visible` treatment for keyboard focus on custom controls.
    func pickyHubFocusRing(isFocused: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius + PickyHubTheme.focusRingOffset, style: .continuous)
                    .stroke(PickyHubTheme.focusRingColor, lineWidth: PickyHubTheme.focusRingWidth)
                    .padding(-PickyHubTheme.focusRingOffset)
            }
        }
    }

    func pickyHubSubtleShadow() -> some View {
        shadow(
            color: PickyHubTheme.Shadow.subtleColor,
            radius: PickyHubTheme.Shadow.subtleRadius,
            x: 0,
            y: PickyHubTheme.Shadow.subtleY
        )
    }
}
