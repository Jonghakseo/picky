//
//  PickyHubComponents.swift
//  Picky
//
//  Shared building blocks for hub pages: page/section headings, card chrome,
//  buttons, pills, and empty/error states. Every page composes these so the
//  seven screens read as one product.
//

import SwiftUI

// MARK: - Content measure

private struct PickyHubContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = PickyHubTheme.Layout.contentMaxWidth
}

extension EnvironmentValues {
    /// Width of the main content column, provided above each page by the hub
    /// root so page-level grid policies receive the current window width.
    var pickyHubContentWidth: CGFloat {
        get { self[PickyHubContentWidthKey.self] }
        set { self[PickyHubContentWidthKey.self] = newValue }
    }
}

/// Column count policy shared by every card grid in the hub.
enum PickyHubGridPolicy {
    static func contentWidth(forViewportWidth width: CGFloat) -> CGFloat {
        max(0, min(PickyHubTheme.Layout.contentMaxWidth, width - PickyHubTheme.Layout.contentHorizontalPadding * 2))
    }

    static func columnCount(for contentWidth: CGFloat, maximum: Int = 3, minimumCardWidth: CGFloat = 0, spacing: CGFloat = 0) -> Int {
        let count: Int
        if contentWidth >= PickyHubTheme.Layout.threeColumnMinWidth {
            count = 3
        } else if contentWidth >= PickyHubTheme.Layout.twoColumnMinWidth {
            count = 2
        } else {
            count = 1
        }
        let fittingCount = minimumCardWidth > 0 ? max(1, Int((max(0, contentWidth) + spacing) / (minimumCardWidth + spacing))) : count
        return max(1, min(count, maximum, fittingCount))
    }
}

/// Standard scrolling page body: centered column, mockup insets, and the
/// measured width published into the environment. Pages that need their own
/// scroll ownership (the conversation page) do not use this.
struct PickyHubPageScroll<Content: View>: View {
    var showsIndicators = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: showsIndicators) {
            content()
                .frame(maxWidth: PickyHubTheme.Layout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, PickyHubTheme.Layout.contentHorizontalPadding)
                .padding(.top, PickyHubTheme.Layout.contentTopPadding)
                .padding(.bottom, PickyHubTheme.Layout.contentBottomPadding)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Headings

struct PickyHubPageHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.pageTitle, weight: .heavy)
                .tracking(-0.8)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 26)
    }
}

/// Section heading with the mockup's blue glyph above the title and an
/// optional trailing text link ("모두 보기").
struct PickyHubSectionHeading: View {
    let systemImage: String?
    let title: LocalizedStringKey
    var linkTitle: LocalizedStringKey?
    var linkAction: (() -> Void)?

    init(systemImage: String? = nil, title: LocalizedStringKey, linkTitle: LocalizedStringKey? = nil, linkAction: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.linkTitle = linkTitle
        self.linkAction = linkAction
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .pickyFont(size: 26, weight: .semibold)
                        .foregroundColor(PickyHubTheme.Colors.action)
                        .frame(height: 31)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .pickyFont(size: PickyHubTheme.Typography.sectionTitle, weight: .heavy)
                    .tracking(-1)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            if let linkTitle, let linkAction {
                PickyHubTextLink(title: linkTitle, action: linkAction)
                    .padding(.bottom, 4)
            }
        }
        .padding(.bottom, PickyHubTheme.Layout.sectionHeadingBottom)
    }
}

/// Smaller heading used inside pages (mockup `.section h2`, 18px).
struct PickyHubSubsectionTitle: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title)
            .pickyFont(size: 18, weight: .bold)
            .tracking(-0.5)
            .foregroundColor(PickyHubTheme.Colors.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 12)
    }
}

struct PickyHubTextLink: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .bold)
                .foregroundColor(PickyHubTheme.Colors.action)
                .underline(isHovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: 4)
        .onHover { isHovering = $0 }
        .animation(PickyHubTheme.Motion.hover, value: isHovering)
    }
}

// MARK: - Card chrome

struct PickyHubCardStyle: ViewModifier {
    var radius: CGFloat = PickyHubTheme.Radius.cardCompact
    var fill: Color = PickyHubTheme.Colors.surface
    var border: Color = PickyHubTheme.Colors.border
    var shadow = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .modifier(OptionalShadow(enabled: shadow))
    }

    private struct OptionalShadow: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.pickyHubSubtleShadow() } else { content }
        }
    }
}

extension View {
    func pickyHubCard(
        radius: CGFloat = PickyHubTheme.Radius.cardCompact,
        fill: Color = PickyHubTheme.Colors.surface,
        border: Color = PickyHubTheme.Colors.border,
        shadow: Bool = false
    ) -> some View {
        modifier(PickyHubCardStyle(radius: radius, fill: fill, border: border, shadow: shadow))
    }
}

// MARK: - Buttons

/// Outline pill with Action Blue text (mockup `.action-button`).
struct PickyHubPillButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isBusy = false
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .pickyFont(size: 10, weight: .bold)
                }
                Text(title)
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .bold)
                    .lineLimit(1)
            }
            .foregroundColor(PickyHubTheme.Colors.action)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? PickyHubTheme.Colors.actionTint : PickyHubTheme.Colors.canvas)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.border, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PickyHubPressStyle())
        .disabled(isBusy)
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Radius.pill)
        .onHover { isHovering = $0 }
        .animation(PickyHubTheme.Motion.hover, value: isHovering)
    }
}

enum PickyHubButtonRole {
    case primary
    case secondary
    case danger
}

/// Rectangular button in three roles (mockup `.primary-button`,
/// `.secondary-button`, `.danger-button`).
struct PickyHubButton: View {
    let title: LocalizedStringKey
    var role: PickyHubButtonRole = .primary
    var systemImage: String?
    var isBusy = false
    var isEnabled = true
    var minWidth: CGFloat? = nil
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .pickyFont(size: 11, weight: .bold)
                }
                Text(title)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .bold)
                    .lineLimit(1)
            }
            .foregroundColor(foreground)
            .frame(minWidth: minWidth)
            .padding(.horizontal, 11)
            .frame(minHeight: 33)
            .background(
                RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(PickyHubPressStyle())
        .disabled(isBusy || !isEnabled)
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Radius.control)
        .onHover { isHovering = $0 }
        .animation(PickyHubTheme.Motion.hover, value: isHovering)
    }

    private var foreground: Color {
        switch role {
        case .primary: PickyHubTheme.Colors.textOnAction
        case .secondary: PickyHubTheme.Colors.textSecondary
        case .danger: PickyHubTheme.Colors.danger
        }
    }

    private var background: Color {
        switch role {
        case .primary: isHovering ? PickyHubTheme.Colors.actionHover : PickyHubTheme.Colors.action
        case .secondary: isHovering ? PickyHubTheme.Colors.actionTint : PickyHubTheme.Colors.canvas
        case .danger: isHovering ? PickyHubTheme.Colors.dangerTint : PickyHubTheme.Colors.canvas
        }
    }

    private var borderColor: Color {
        switch role {
        case .primary: isHovering ? PickyHubTheme.Colors.actionHover : PickyHubTheme.Colors.action
        case .secondary: isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.border
        case .danger: PickyHubTheme.Colors.danger
        }
    }
}

/// Circular 34pt icon button (mockup `.icon-button`).
struct PickyHubIconCircleButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    var fill: Color = PickyHubTheme.Colors.canvas
    var foreground: Color = PickyHubTheme.Colors.textSecondary
    var border: Color = PickyHubTheme.Colors.border
    var hoverForeground: Color = PickyHubTheme.Colors.action
    var size: CGFloat = 34
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .pickyFont(size: 14, weight: .semibold)
                .foregroundColor(isHovering ? hoverForeground : foreground)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .overlay(Circle().stroke(isHovering ? hoverForeground : border, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PickyHubPressStyle())
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: size / 2)
        .onHover { isHovering = $0 }
        .animation(PickyHubTheme.Motion.hover, value: isHovering)
        .help(Text(accessibilityLabel))
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// Press feedback shared by hub buttons: 1pt sink, no colour change (colour is
/// owned by the hover state of each button).
struct PickyHubPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(PickyHubTheme.Motion.hover, value: configuration.isPressed)
    }
}

// MARK: - Pills / badges

/// Small outlined chip (mockup `.stat-badge`, `.insight-badge`).
struct PickyHubBadgePill: View {
    let text: String
    var onAccent = false

    var body: some View {
        Text(text)
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
            .monospacedDigit()
            .foregroundColor(onAccent ? PickyHubTheme.Colors.textOnAction : PickyHubTheme.Colors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(onAccent ? Color.white.opacity(0.16) : PickyHubTheme.Colors.canvas)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(onAccent ? Color.white.opacity(0.46) : PickyHubTheme.Colors.border.opacity(0.9), lineWidth: 1)
            )
            .fixedSize()
    }
}

/// Neutral status badge (mockup `.status-badge`).
struct PickyHubStatusBadge: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .bold)
            .foregroundColor(PickyHubTheme.Colors.badgeText)
            .padding(.horizontal, 9)
            .frame(minWidth: 52, minHeight: 33)
            .background(
                RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous)
                    .fill(PickyHubTheme.Colors.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous)
                    .stroke(PickyHubTheme.Colors.border, lineWidth: 1)
            )
    }
}

// MARK: - States

/// Centered empty state (mockup `.empty-state`).
struct PickyHubEmptyState: View {
    var systemImage: String = "tray"
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var actionSystemImage: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .pickyFont(size: 22, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.action)
                .frame(width: 52, height: 52)
                .background(Circle().fill(PickyHubTheme.Colors.actionTint))
                .accessibilityHidden(true)
            Text(title)
                .pickyFont(size: 18, weight: .bold)
                .tracking(-0.4)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                PickyHubButton(title: actionTitle, role: .primary, systemImage: actionSystemImage, action: action)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 24)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
    }
}

enum PickyHubInlineStatusTone {
    case neutral
    case success
    case error
    case warning
}

/// Inline status/error line with an optional action (typically "다시 시도").
struct PickyHubInlineStatus: View {
    let tone: PickyHubInlineStatusTone
    let message: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(color)
                .accessibilityHidden(true)
            Text(message)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(tone == .error ? DS.Colors.destructiveText : PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                PickyHubTextLink(title: actionTitle, action: action)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch tone {
        case .neutral: "info.circle"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .neutral: PickyHubTheme.Colors.textTertiary
        case .success: PickyHubTheme.Colors.success
        case .error: DS.Colors.destructiveText
        case .warning: PickyHubTheme.Colors.warning
        }
    }
}

/// Loading placeholder for asynchronous sections.
struct PickyHubLoadingRow: View {
    let message: LocalizedStringKey
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(message)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .pickyHubCard()
    }
}

/// Neutral placeholder block that stands in for a thumbnail.
struct PickyHubPlaceholderVisual: View {
    var cornerRadius: CGFloat = PickyHubTheme.Radius.control
    var systemImage: String?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(PickyHubTheme.Colors.muted)
            if let systemImage {
                Image(systemName: systemImage)
                    .pickyFont(size: 22, weight: .semibold)
                    .foregroundColor(Color.white.opacity(0.85))
            }
        }
        .accessibilityHidden(true)
    }
}
