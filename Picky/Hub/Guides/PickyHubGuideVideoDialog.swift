//
//  PickyHubGuideVideoDialog.swift
//  Picky
//

import AppKit
import SwiftUI

struct PickyHubGuideVideoDialog: View {
    let entry: PickyHubGuideEntry
    @EnvironmentObject private var modalHost: PickyHubModalHost
    @State private var loadState: PickyHubYouTubePlayerLoadState = .loading
    @State private var reloadID = UUID()

    init(entry: PickyHubGuideEntry) {
        self.entry = entry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubModalHeader(
                meta: "\(L10n.t(entry.kind.titleKey)) · \(longDate)",
                title: entry.title.resolved(for: LocaleManager.shared.effectiveLocale),
                onClose: { modalHost.dismiss() }
            )
            .padding(20)

            player
        }
        .onDisappear { loadState = .loading }
    }

    @ViewBuilder
    private var player: some View {
        switch loadState {
        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .pickyFont(size: 22, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.warning)
                    .accessibilityHidden(true)
                Text("hub.guides.video.error.title")
                    .pickyFont(size: 16, weight: .bold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                Text("hub.guides.video.error.message")
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    PickyHubButton(title: "hub.guides.video.retry", role: .secondary, systemImage: "arrow.clockwise") {
                        loadState = .loading
                        reloadID = UUID()
                    }
                    if let watchURL = entry.watchURL {
                        PickyHubButton(title: "hub.guides.video.openYouTube", role: .primary, systemImage: "arrow.up.right") {
                            NSWorkspace.shared.open(watchURL)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 384)
            .padding(.horizontal, 24)
            .background(PickyHubTheme.Colors.canvas)
        case .loading, .loaded:
            ZStack {
                PickyHubYouTubePlayerView(url: entry.embedURL) { state in
                    loadState = state
                }
                .id(reloadID)
                .opacity(loadState == .loaded ? 1 : 0)

                if loadState == .loading {
                    ProgressView("hub.guides.video.loading")
                        .controlSize(.small)
                        .tint(PickyHubTheme.Colors.action)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(PickyHubTheme.Colors.textPrimary)
        }
    }

    private var longDate: String {
        guard let date = entry.publishedDate else { return entry.publishedOn }
        return date.formatted(.dateTime.year().month(.wide).day())
    }
}
