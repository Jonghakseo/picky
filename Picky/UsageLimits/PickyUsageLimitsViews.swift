//
//  PickyUsageLimitsViews.swift
//  Picky
//
//  Plan-limit surfaces: the Hub "Plan limits" cards (Statistics > AI usage)
//  and the compact section inside the HUD conversation-context popover.
//

import AppKit
import SwiftUI

struct PickyUsageProviderLogo: View {
    let provider: PickyUsageLimitsProviderID
    let size: CGFloat
    var color: Color

    var body: some View {
        Image(provider.logoAssetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundColor(color)
            .accessibilityHidden(true)
    }

    /// Claude keeps its brand orange in the Hub; ChatGPT follows the text color.
    static func hubColor(for provider: PickyUsageLimitsProviderID) -> Color {
        switch provider {
        case .anthropic: Color(hex: "#D97757")
        case .openaiCodex: PickyHubTheme.Colors.textPrimary
        }
    }
}

// MARK: - Hub

struct PickyHubUsageLimitsSection: View {
    @ObservedObject var store: PickyUsageLimitsStore
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        let providers = store.providers
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    PickyHubSubsectionTitle(title: "usageLimits.title")
                    Spacer(minLength: PickyHubTheme.Spacing.related)
                    PickyHubTextLink(title: "hub.stats.refresh") { store.refresh() }
                        .disabled(store.isRefreshing)
                }
                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: PickyHubTheme.Spacing.field, alignment: .top),
                    count: PickyHubGridPolicy.columnCount(for: contentWidth / fontScale, maximum: 2, spacing: PickyHubTheme.Spacing.field)
                )
                TimelineView(.everyMinute) { context in
                    LazyVGrid(columns: columns, alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                        ForEach(providers) { provider in
                            PickyHubUsageLimitCard(
                                provider: provider,
                                now: context.date,
                                isPinned: Binding(
                                    get: { store.isPinned(provider.provider) },
                                    set: { store.setPinned($0, for: provider.provider) }
                                )
                            )
                        }
                    }
                }
                Text("usageLimits.caption")
                    .pickyFont(size: PickyHubTheme.Typography.caption)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, PickyHubTheme.Spacing.related)
            }
            .padding(.top, PickyHubTheme.Spacing.group)
        }
    }
}

struct PickyHubUsageLimitCard: View {
    let provider: PickyUsageLimitsProvider
    let now: Date
    @Binding var isPinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            header
            PickyHubUsageLimitRow(title: "usageLimits.session", window: provider.session, kind: .session, now: now, dimmed: provider.isStale)
            PickyHubUsageLimitRow(title: "usageLimits.weekly", window: provider.weekly, kind: .weekly, now: now, dimmed: provider.isStale)
            if provider.isStale {
                Text(provider.checkedAt == nil ? "usageLimits.error.unavailable" : "usageLimits.error.stale")
                    .pickyFont(size: PickyHubTheme.Typography.caption)
                    .foregroundColor(PickyHubTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(provider.errorMessage ?? "")
            }
            Divider().overlay(PickyHubTheme.Colors.borderSoft)
            resetsRow
            HStack(spacing: PickyHubTheme.Spacing.related) {
                PickyHubUsageLinkButton(title: "usageLimits.link.status", url: provider.provider.statusURL)
                PickyHubUsageLinkButton(title: "usageLimits.link.dashboard", url: provider.provider.dashboardURL)
            }
            Toggle(isOn: $isPinned) {
                Text("usageLimits.menuBar.toggle")
                    .foregroundStyle(PickyHubTheme.Colors.textSecondary)
            }
            .toggleStyle(.checkbox)
            .tint(PickyHubTheme.Colors.action)
            .pickyFont(size: PickyHubTheme.Typography.bodySmall)
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .pickyHubCard()
    }

    private var header: some View {
        HStack(spacing: PickyHubTheme.Spacing.related) {
            PickyUsageProviderLogo(provider: provider.provider, size: 18, color: PickyUsageProviderLogo.hubColor(for: provider.provider))
            Text(verbatim: provider.provider.displayName)
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            if let plan = provider.plan {
                Text(verbatim: plan)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.badgeText)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(PickyHubTheme.Colors.navHighlight))
            }
            Spacer(minLength: PickyHubTheme.Spacing.related)
            Text(verbatim: PickyUsageLimitsPresentation.checkedText(provider, now: now))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: provider.isStale ? .medium : .regular)
                .foregroundColor(provider.isStale ? PickyHubTheme.Colors.warning : PickyHubTheme.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    private var resetsRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("usageLimits.resets.title")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            Spacer(minLength: PickyHubTheme.Spacing.related)
            HStack(spacing: 6) {
                if let resets = provider.resets, resets.available > 0, let expiresAt = resets.nextExpiresAt {
                    Circle()
                        .fill(deadlineColor(PickyUsageResetDeadlineTone(expiresAt: expiresAt, now: now)))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(verbatim: PickyUsageLimitsPresentation.resetsText(provider.resets))
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                    .monospacedDigit()
                    .foregroundColor((provider.resets?.available ?? 0) > 0 ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textTertiary)
            }
            .help(resetsHelp)
        }
        .accessibilityElement(children: .combine)
    }

    private var resetsHelp: String {
        guard let expiresAt = provider.resets?.nextExpiresAt, (provider.resets?.available ?? 0) > 0 else { return "" }
        return L10n.t("usageLimits.resets.expires", PickyUsageLimitsPresentation.durationText(until: expiresAt, now: now))
    }

    private func deadlineColor(_ tone: PickyUsageResetDeadlineTone) -> Color {
        switch tone {
        case .later: PickyHubTheme.Colors.action
        case .withinWeek: DS.Colors.warning
        case .within48Hours: DS.Colors.destructive
        }
    }
}

struct PickyHubUsageLimitRow: View {
    let title: LocalizedStringKey
    let window: PickyUsageLimitWindow?
    let kind: PickyUsageLimitWindowKind
    let now: Date
    let dimmed: Bool

    var body: some View {
        let tone = PickyUsageLimitTone(window: window)
        // Stale values have no trustworthy pace against the current clock.
        let pace = dimmed ? nil : PickyUsageLimitPace(window: window, kind: kind, now: now)
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            PickyUsageLimitBar(
                fraction: window?.remainingFraction,
                fill: Self.barColor(tone),
                track: PickyHubTheme.Colors.barTrack,
                marker: pace?.expectedRemainingFraction,
                markerColor: PickyHubTheme.Colors.textPrimary.opacity(0.55)
            )
                .frame(height: 6)
            HStack(alignment: .firstTextBaseline, spacing: PickyHubTheme.Spacing.related) {
                Text(verbatim: PickyUsageLimitsPresentation.remainingText(window))
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                    .monospacedDigit()
                    .foregroundColor(Self.textColor(tone))
                if pace?.isAhead == true {
                    Text("usageLimits.pace.ahead")
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                        .foregroundColor(DS.Colors.warningText)
                        .lineLimit(1)
                        .help(L10n.t("usageLimits.pace.help", Int(((pace?.expectedRemainingFraction ?? 0) * 100).rounded())))
                }
                Spacer(minLength: PickyHubTheme.Spacing.related)
                Text(verbatim: PickyUsageLimitsPresentation.resetText(window, now: now))
                    .pickyFont(size: PickyHubTheme.Typography.caption)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    static func barColor(_ tone: PickyUsageLimitTone) -> Color {
        switch tone {
        case .normal: PickyHubTheme.Colors.action
        case .warning: DS.Colors.warning
        case .danger: DS.Colors.destructive
        case .unknown: PickyHubTheme.Colors.muted
        }
    }

    static func textColor(_ tone: PickyUsageLimitTone) -> Color {
        switch tone {
        case .normal: PickyHubTheme.Colors.textPrimary
        case .warning: PickyHubTheme.Colors.warning
        case .danger: PickyHubTheme.Colors.danger
        case .unknown: PickyHubTheme.Colors.textTertiary
        }
    }
}

struct PickyUsageLimitBar: View {
    /// Remaining share; `nil` draws an empty track.
    let fraction: Double?
    let fill: Color
    let track: Color
    /// Even-pace remaining share, drawn as a thin tick across the bar.
    var marker: Double? = nil
    var markerColor: Color = .clear

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if let fraction {
                    Capsule()
                        .fill(fill)
                        .frame(width: geometry.size.width * CGFloat(max(0, min(1, fraction))))
                }
                if let marker {
                    Rectangle()
                        .fill(markerColor)
                        .frame(width: 1.5, height: geometry.size.height + 6)
                        .offset(x: geometry.size.width * CGFloat(max(0, min(1, marker))) - 0.75)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PickyHubUsageLinkButton: View {
    let title: LocalizedStringKey
    let url: URL
    @State private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
            .foregroundColor(PickyHubTheme.Colors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous)
                    .fill(isHovering ? PickyHubTheme.Colors.border : PickyHubTheme.Colors.navHighlight)
            )
            .contentShape(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(PickyHubPressStyle())
        .onHover { isHovering = $0 }
        .help(url.absoluteString)
    }
}

// MARK: - HUD context popover

/// Plan limits for the provider the Pickle's model runs on. Hidden when that
/// provider is not a subscription Picky is signed in to.
struct PickyHUDUsageLimitsSection: View {
    @ObservedObject var store: PickyUsageLimitsStore
    let providerID: PickyUsageLimitsProviderID
    var onOpenHub: () -> Void

    var body: some View {
        if let provider = store.provider(providerID) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: DS.Spacing.space3) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space2) {
                        Text("usageLimits.title")
                            .font(PickyHUDTypography.labelSemibold)
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer(minLength: DS.Spacing.space1)
                        Text(verbatim: [provider.provider.displayName, provider.plan].compactMap { $0 }.joined(separator: " "))
                            .font(PickyHUDTypography.meta)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    row("usageLimits.session", provider.session, now: context.date)
                    row("usageLimits.weekly", provider.weekly, now: context.date)
                    HStack(alignment: .firstTextBaseline) {
                        Text("usageLimits.resets.title")
                            .font(PickyHUDTypography.status)
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer(minLength: DS.Spacing.space1)
                        Text(verbatim: PickyUsageLimitsPresentation.resetsText(provider.resets))
                            .font(PickyHUDTypography.metaMonospacedSemibold)
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                    if provider.isStale {
                        Text(provider.checkedAt == nil ? "usageLimits.error.unavailable" : "usageLimits.error.stale")
                            .font(PickyHUDTypography.meta)
                            .foregroundColor(DS.Colors.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Button(action: onOpenHub) {
                            Text("usageLimits.openHub")
                                .font(PickyHUDTypography.statusSemibold)
                                .foregroundColor(DS.Colors.accentText)
                                .padding(.horizontal, DS.Spacing.space2)
                                .padding(.vertical, DS.Spacing.space1)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PickyHUDCompactChipButtonStyle())
                    }
                }
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ window: PickyUsageLimitWindow?, now: Date) -> some View {
        let tone = PickyUsageLimitTone(window: window)
        return VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: DS.Spacing.space1)
                Text(verbatim: PickyUsageLimitsPresentation.remainingText(window))
                    .font(PickyHUDTypography.metaMonospacedSemibold)
                    .foregroundColor(Self.textColor(tone))
            }
            PickyUsageLimitBar(fraction: window?.remainingFraction, fill: Self.barColor(tone), track: DS.Colors.surface2.opacity(0.85))
                .frame(height: DS.Spacing.space1)
            Text(verbatim: PickyUsageLimitsPresentation.resetText(window, now: now))
                .font(PickyHUDTypography.meta)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func barColor(_ tone: PickyUsageLimitTone) -> Color {
        switch tone {
        case .normal: DS.Colors.info
        case .warning: DS.Colors.warning
        case .danger: DS.Colors.destructive
        case .unknown: DS.Colors.textTertiary
        }
    }

    private static func textColor(_ tone: PickyUsageLimitTone) -> Color {
        switch tone {
        case .normal: DS.Colors.textPrimary
        case .warning: DS.Colors.warningText
        case .danger: DS.Colors.destructiveText
        case .unknown: DS.Colors.textTertiary
        }
    }
}

// MARK: - Environment

private struct PickyUsageLimitsStoreKey: EnvironmentKey {
    static let defaultValue: PickyUsageLimitsStore? = nil
}

extension EnvironmentValues {
    /// Optional so HUD previews, galleries, and tests render without plan limits.
    var pickyUsageLimitsStore: PickyUsageLimitsStore? {
        get { self[PickyUsageLimitsStoreKey.self] }
        set { self[PickyUsageLimitsStoreKey.self] = newValue }
    }
}
