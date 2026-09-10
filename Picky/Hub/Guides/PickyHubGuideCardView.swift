//
//  PickyHubGuideCardView.swift
//  Picky
//

import SwiftUI

struct PickyHubGuideCardView: View {
    let entry: PickyHubGuideEntry
    var isFocused = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnail
                    .aspectRatio(16 / 9, contentMode: .fit)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: PickyHubTheme.Spacing.related) {
                        Text(LocalizedStringKey(entry.kind.titleKey))
                        Text(displayDate)
                    }
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)

                    Text(entry.title.resolved(for: LocaleManager.shared.effectiveLocale))
                        .pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .bold)
                        .tracking(-0.4)
                        .foregroundColor(PickyHubTheme.Colors.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, PickyHubTheme.Spacing.related)

                    Text(entry.summary.resolved(for: LocaleManager.shared.effectiveLocale))
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, PickyHubTheme.Spacing.related)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PickyHubTheme.Spacing.cardInset)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pickyHubCard(
                radius: PickyHubTheme.Radius.card,
                fill: PickyHubTheme.Colors.surface,
                border: isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.border
            )
            .clipShape(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Radius.card)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.hover, value: isHovering)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text("hub.guides.card.playHint"))
    }

    @ViewBuilder
    private var thumbnail: some View {
        AsyncImage(url: entry.resolvedThumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty:
                PickyHubPlaceholderVisual(systemImage: nil)
                    .overlay { ProgressView().controlSize(.small).tint(.white) }
            case .failure:
                PickyHubPlaceholderVisual(systemImage: "play.rectangle")
            @unknown default:
                PickyHubPlaceholderVisual(systemImage: "play.rectangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }

    private var displayDate: String {
        entry.publishedOn.replacingOccurrences(of: "-", with: ".")
    }

    private var accessibilityLabel: Text {
        Text("\(entry.title.resolved(for: LocaleManager.shared.effectiveLocale)), \(L10n.t(entry.kind.titleKey)), \(displayDate), \(L10n.t("hub.guides.card.playHint"))")
    }
}
