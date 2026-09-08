//
//  PickyHubGuideCardView.swift
//  Picky
//

import SwiftUI

struct PickyHubGuideCardView: View {
    let entry: PickyHubGuideEntry
    var isFocused = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnail
                    .aspectRatio(16 / 9, contentMode: .fit)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Text(entry.kind.titleKey)
                        Text(displayDate)
                    }
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)

                    Text(entry.title.resolved(for: LocaleManager.shared.effectiveLocale))
                        .pickyFont(size: 16, weight: .bold)
                        .tracking(-0.4)
                        .foregroundColor(PickyHubTheme.Colors.textPrimary)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 8)

                    Text(entry.summary.resolved(for: LocaleManager.shared.effectiveLocale))
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PickyHubTheme.Colors.canvas)
            .pickyHubCard(radius: PickyHubTheme.Radius.card, border: isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.border)
            .clipShape(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Radius.card)
        .onHover { isHovering = $0 }
        .animation(PickyHubTheme.Motion.hover, value: isHovering)
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
