import AppKit
import SwiftUI

/// Full stored content, loaded only while the result disclosure is expanded.
struct PickyToolHistoryDetailView: View {
    @ObservedObject var model: PickyToolHistoryDetailModel
    @State private var structured = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
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
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: model.state == .ready ? 320 : nil)

            if model.attachmentsOmitted {
                Text(L10n.t("hud.toolHistory.detail.attachmentsOmitted"))
                    .pickyFont(size: 11)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            footer
        }
        .padding(DS.Spacing.sm)
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
                ScrollView { PickyToolJSONResultView(root: root) }
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
                Button(L10n.t("hud.toolHistory.detail.copyAll")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }
                if model.pageNumber == 1, !model.canLoadNextPage, model.text.utf16.count <= 16_384 {
                    Toggle("JSON", isOn: $structured)
                        .toggleStyle(.checkbox)
                }
                Spacer()
            } else if model.state == .pending || model.state == .failed || model.state == .unavailable {
                Button(L10n.t("hud.toolHistory.detail.retry")) { model.retry() }
            }
        }
        .buttonStyle(.bordered)
    }
}
