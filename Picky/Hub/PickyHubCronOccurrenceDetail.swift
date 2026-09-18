import AppKit
import SwiftUI

/// The calendar explains when; the detail explains what the job is instructed to do.
struct PickyHubCronOccurrenceDetail: View {
    let occurrence: PickyCronCalendarOccurrence
    var prompt: PickyCronPromptReadResult = .missing
    var isHistoricalPrompt = false
    @State private var promptHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            Text(occurrence.job.name)
                .pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                Label {
                    Text(occurrence.date, format: .dateTime.month().day().weekday().hour().minute())
                } icon: { Image(systemName: "calendar") }
                Label(PickyCronCalendarPresentation.schedule(occurrence.job), systemImage: "repeat")
            }
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
            .foregroundColor(PickyHubTheme.Colors.textSecondary)
            Divider()
            HStack {
                Text(isHistoricalPrompt ? "hub.calendar.historicalInstructions" : "hub.calendar.instructions")
                    .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                Spacer()
                if case .loaded(let text) = prompt {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(L10n.t("hub.calendar.copyInstructions"))
                    .accessibilityLabel(Text("hub.calendar.copyInstructions"))
                }
            }
            promptContent
            if let rule = occurrence.job.schedule {
                DisclosureGroup("hub.calendar.rawRule") {
                    Text(rule).monospaced().textSelection(.enabled)
                }
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(width: 420, alignment: .leading)
    }

    @ViewBuilder private var promptContent: some View {
        switch prompt {
        case .loaded(let text):
            ScrollView {
                Text(text)
                    .pickyFont(size: PickyHubTheme.Typography.body, weight: .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PickyCronPromptHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .frame(height: min(320, max(64, promptHeight)))
            .onPreferenceChange(PickyCronPromptHeightKey.self) { promptHeight = $0 }
        case .missing:
            promptError("hub.calendar.promptMissing")
        case .tooLarge:
            promptError("hub.calendar.promptTooLarge")
        case .unsafePath:
            promptError("hub.calendar.promptUnsafe")
        case .unreadable:
            promptError("hub.calendar.promptUnreadable")
        }
    }

    private func promptError(_ key: LocalizedStringKey) -> some View {
        Label(key, systemImage: "exclamationmark.triangle")
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
            .foregroundColor(PickyHubTheme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PickyCronPromptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
