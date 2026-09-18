import AppKit
import SwiftUI

/// A bounded page of the original stored arguments or result, separate from the live history list.
struct PickyToolHistoryDetailView: View {
    @ObservedObject var model: PickyToolHistoryDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var structured = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text(model.toolName)
                    .pickyFont(size: 14, weight: .semibold, design: .monospaced)
                Spacer()
                Button(L10n.t("hud.toolHistory.detail.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(L10n.t("hud.toolHistory.detail.scope"))
                .pickyFont(size: 11)
                .foregroundStyle(DS.Colors.textSecondary)
            Picker(L10n.t("hud.toolHistory.detail.part"), selection: Binding(
                get: { model.part },
                set: { model.load(part: $0) }
            )) {
                Text(L10n.t("hud.toolHistory.detail.arguments")).tag(PickyToolHistoryDetailPart.arguments)
                Text(L10n.t("hud.toolHistory.result.label")).tag(PickyToolHistoryDetailPart.result)
            }
            .pickerStyle(.segmented)
            .disabled(model.state == .sourceChanged)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if model.attachmentsOmitted {
                Text(L10n.t("hud.toolHistory.detail.attachmentsOmitted"))
                    .pickyFont(size: 11)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            footer
        }
        .padding(DS.Spacing.lg)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 540)
        .background(DS.Colors.surface1)
        .task { if model.state == .idle { await model.load(part: .result).value } }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView(L10n.t("hud.toolHistory.detail.loading"))
        case .ready:
            if structured, model.pageNumber == 1, !model.canLoadNextPage, model.text.utf16.count <= 16_384,
               case .json(let root, _) = PickyToolResultPresentation.make(from: PickyToolHistoryResult(
                text: model.text, isTruncated: false, isRepaired: false
               )) {
                PickyToolJSONResultView(root: root)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(model.text.isEmpty ? L10n.t("hud.toolHistory.detail.empty") : model.text)
                        .pickyFont(size: 12, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(DS.Spacing.sm)
                }
                .background(DS.Colors.surface2)
            }
        case .pending: status("pending")
        case .unavailable: status("unavailable")
        case .sourceChanged: status("sourceChanged")
        case .unsupported: status("unsupported")
        case .failed: status("failed")
        }
    }

    private func status(_ key: String) -> some View {
        Text(L10n.t("hud.toolHistory.detail.\(key)"))
            .pickyFont(size: 12)
            .foregroundStyle(DS.Colors.textSecondary)
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            if model.state == .ready {
                Text(L10n.t("hud.toolHistory.detail.page", Int64(model.pageNumber)))
                    .font(PickyHUDTypography.metaMonospacedMedium)
                Button(L10n.t("hud.toolHistory.detail.copyPage")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }
                if model.pageNumber == 1, !model.canLoadNextPage, model.text.utf16.count <= 16_384 {
                    Toggle("JSON", isOn: $structured)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                if model.pageNumber > 1 {
                    Button(L10n.t("hud.toolHistory.detail.firstPage")) { model.load(part: model.part) }
                }
                Button(L10n.t("hud.toolHistory.detail.nextPage")) { model.loadNextPage() }
                    .disabled(!model.canLoadNextPage)
            } else if model.state == .pending || model.state == .failed || model.state == .unavailable {
                Button(L10n.t("hud.toolHistory.detail.retry")) { model.retry() }
            }
        }
        .buttonStyle(.bordered)
    }
}
