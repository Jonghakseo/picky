//
//  PickyHubGuidesPage.swift
//  Picky
//

import SwiftUI

struct PickyHubGuidesPage: View {
    let dependencies: PickyHubDependencies
    @EnvironmentObject private var modalHost: PickyHubModalHost
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @FocusState private var focusedGuideID: String?
    @State private var entries: [PickyHubGuideEntry] = []

    var body: some View {
        PickyHubPageScroll {
            PickyHubPageHeader(title: PickyHubPage.guides.titleKey, subtitle: "hub.page.guides.subtitle")

            if entries.isEmpty {
                PickyHubEmptyState(
                    systemImage: "play.rectangle",
                    title: "hub.guides.empty.title",
                    message: "hub.guides.empty.message"
                )
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(entries) { entry in
                        PickyHubGuideCardView(
                            entry: entry,
                            isFocused: focusedGuideID == entry.id,
                            action: { present(entry) }
                        )
                        .focused($focusedGuideID, equals: entry.id)
                    }
                }
                .accessibilityLabel(Text("hub.guides.feed.accessibilityLabel"))
            }
        }
        .onAppear {
            if entries.isEmpty { entries = PickyHubGuideCatalog.load() }
        }
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: PickyHubTheme.Layout.cardMinWidth), spacing: PickyHubTheme.Layout.cardGap),
            count: PickyHubGridPolicy.columnCount(for: contentWidth, maximum: 2)
        )
    }

    private func present(_ entry: PickyHubGuideEntry) {
        focusedGuideID = entry.id
        modalHost.present(width: 720, accessibilityLabel: entry.title.resolved(for: LocaleManager.shared.effectiveLocale), onDismiss: {
            focusedGuideID = entry.id
        }) {
            PickyHubGuideVideoDialog(entry: entry)
        }
    }
}
