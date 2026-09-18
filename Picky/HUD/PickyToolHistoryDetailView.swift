import AppKit
import SwiftUI

/// Expanded history content owns no session state. Arguments and results stay independent so
/// inspecting a raw payload never discards the formatted result or its pagination.
struct PickyToolHistoryDetailView: View {
    @ObservedObject var model: PickyToolHistoryDetailModel
    @ObservedObject var argumentsModel: PickyToolHistoryDetailModel
    let entry: PickyToolHistoryEntry
    var workingDirectory: String? = nil
    @State private var presentation: PickyToolHistoryPresentation.Detail?
    @State private var auxiliary: Auxiliary?
    @State private var hovering = false
    @FocusState private var menuFocused: Bool

    private enum Auxiliary { case arguments, response, attempted, timing }

    private struct PresentationInput: Equatable {
        let arguments: String?
        let structuredResult: String?
        let status: PickyToolHistoryStatus
    }

    init(model: PickyToolHistoryDetailModel, argumentsModel: PickyToolHistoryDetailModel,
         entry: PickyToolHistoryEntry, workingDirectory: String? = nil) {
        self.model = model
        self.argumentsModel = argumentsModel
        self.entry = entry
        self.workingDirectory = workingDirectory
        _presentation = State(initialValue: PickyToolHistoryPresentation.detail(
            for: entry, arguments: argumentsModel.state == .ready ? argumentsModel.text : nil,
            structuredResult: model.structuredResult
        ))
    }

    private var presentationInput: PresentationInput {
        PresentationInput(arguments: argumentsModel.state == .ready ? argumentsModel.text : nil,
                          structuredResult: model.structuredResult, status: entry.status)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.space1) {
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                primaryContent
                if model.attachmentsOmitted {
                    Text(L10n.t("hud.toolHistory.detail.attachmentsOmitted"))
                        .font(PickyHUDTypography.status)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                if let auxiliary { auxiliaryContent(auxiliary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .opacity(hovering || menuFocused || auxiliary != nil ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .onChange(of: presentationInput) { _, input in
            presentation = PickyToolHistoryPresentation.detail(
                for: entry, arguments: input.arguments, structuredResult: input.structuredResult
            )
        }
        .task {
            let resultTask = model.state == .idle ? model.load(part: .result) : nil
            let argumentsTask = argumentsModel.state == .idle ? argumentsModel.load(part: .arguments) : nil
            await resultTask?.value
            await argumentsTask?.value
        }
        .onChange(of: entry.status) { old, new in
            if old == .running && new != .running && model.state == .pending {
                model.retry()
            }
        }
        .onDisappear { model.cancel(); argumentsModel.cancel() }
    }

    @ViewBuilder private var primaryContent: some View {
        if model.state == .sourceChanged || argumentsModel.state == .sourceChanged {
            status("sourceChanged")
        } else if entry.status == .failed {
            if let path = storedFilePath {
                PickyToolHistoryFileLink(path: path, workingDirectory: workingDirectory)
            }
            resultContent
        } else if let presentation {
            PickyToolHistoryContentView(presentation: presentation, workingDirectory: workingDirectory)
            if case .ask(_, .unavailable) = presentation {
                resultContent
            } else if model.state != .ready {
                resultContent
            }
        } else {
            if let path = storedFilePath {
                PickyToolHistoryFileLink(path: path, workingDirectory: workingDirectory)
            }
            if entry.category == .bash, argumentsModel.state == .ready,
               let command = PickyToolHistoryRenderer.parseArgs(argumentsModel.text)["command"] as? String {
                PickyToolHistoryTextBlock(text: "$ " + command, tint: DS.Colors.textSecondary)
            }
            if case let .subagent(_, agents, task) = entry.detail {
                if !agents.isEmpty {
                    Text(agents.joined(separator: ", "))
                        .font(PickyHUDTypography.supporting).foregroundStyle(DS.Colors.textSecondary)
                }
                if let task {
                    Text(task).font(PickyHUDTypography.body).textSelection(.enabled)
                }
            }
            resultContent
            // Known mutating tools must not masquerade as a complete structured view
            // while their original input is missing or still loading.
            if needsOriginalArguments && argumentsModel.state != .ready {
                Text(L10n.t("hud.toolHistory.argumentsUnavailable"))
                    .font(PickyHUDTypography.status)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }

    private var needsOriginalArguments: Bool {
        ["edit", "multiedit", "write", "todo_write", "todowrite", "ask_user_question"].contains(entry.name.lowercased())
    }

    private var storedFilePath: String? {
        guard argumentsModel.state == .ready else { return nil }
        let args = PickyToolHistoryRenderer.parseArgs(argumentsModel.text)
        guard entry.category == .read || entry.category == .edit || entry.category == .write else { return nil }
        return ["path", "file", "file_path", "filePath"].compactMap { args[$0] as? String }.first
    }

    @ViewBuilder private var resultContent: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView(L10n.t("hud.toolHistory.detail.loading"))
                .controlSize(.small).font(PickyHUDTypography.status)
        case .ready:
            PickyToolHistoryTextBlock(text: model.text, tint: entry.status == .failed ? DS.Colors.destructiveText : DS.Colors.textBody)
        case .pending: status("pending")
        case .unavailable: status("unavailable")
        case .sourceChanged: status("sourceChanged")
        case .unsupported: status("unsupported")
        case .failed: status("failed")
        }
        if let preview = storedPreview {
            Text(L10n.t(preview.isTruncated
                        ? "hud.toolHistory.detail.storedPreviewTruncated"
                        : "hud.toolHistory.detail.storedPreview"))
                .font(PickyHUDTypography.status)
                .foregroundStyle(DS.Colors.textSecondary)
            PickyToolHistoryTextBlock(text: preview.text,
                                      tint: entry.status == .failed ? DS.Colors.destructiveText : DS.Colors.textBody)
        }
        if [.pending, .unavailable, .failed].contains(model.state) {
            Button(L10n.t("hud.toolHistory.detail.retry")) { model.retry() }
                .buttonStyle(.plain).foregroundStyle(DS.Colors.accentText)
                .font(PickyHUDTypography.status)
        }
    }

    private var storedPreview: PickyToolHistoryResult? {
        guard [.unsupported, .unavailable, .failed].contains(model.state),
              argumentsModel.state != .sourceChanged else { return nil }
        return entry.result
    }

    private func status(_ key: String) -> some View {
        Text(L10n.t("hud.toolHistory.detail.\(key)"))
            .font(PickyHUDTypography.status)
            .foregroundStyle(DS.Colors.textSecondary)
    }

    private var actions: some View {
        Menu {
            Button(L10n.t(storedPreview == nil
                          ? "hud.toolHistory.detail.copyAll" : "hud.toolHistory.detail.copyPreview")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(storedPreview?.text ?? model.text, forType: .string)
            }.disabled(model.state != .ready && storedPreview == nil)
            Divider()
            Button(L10n.t("hud.toolHistory.rawResponse")) { auxiliary = .response }
            Button(L10n.t("hud.toolHistory.detail.arguments")) { auxiliary = .arguments }
            if entry.status == .failed, presentation != nil {
                Button(L10n.t("hud.toolHistory.attempted")) { auxiliary = .attempted }
            }
            Button(L10n.t("hud.toolHistory.timing")) { auxiliary = .timing }
            if argumentsModel.state == .failed || argumentsModel.state == .unavailable || argumentsModel.state == .pending {
                Button(L10n.t("hud.toolHistory.retryArguments")) { argumentsModel.retry() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(PickyHUDTypography.supporting)
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focused($menuFocused)
        .help(L10n.t("hud.toolHistory.more"))
        .accessibilityLabel(L10n.t("hud.toolHistory.more"))
    }

    private func auxiliaryContent(_ selected: Auxiliary) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            HStack {
                Text(auxiliaryTitle(selected)).font(PickyHUDTypography.status)
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                Button { auxiliary = nil } label: {
                    Image(systemName: "xmark").font(PickyHUDTypography.status).frame(width: 24, height: 24)
                }
                .buttonStyle(PickyToolHistoryQuietButtonStyle())
                .accessibilityLabel(L10n.t("hud.toolHistory.detail.close"))
            }
            switch selected {
            case .response: resultContent
            case .arguments:
                if argumentsModel.state == .ready {
                    PickyToolHistoryTextBlock(text: argumentsModel.text)
                } else {
                    Text(L10n.t("hud.toolHistory.argumentsUnavailable"))
                        .font(PickyHUDTypography.status).foregroundStyle(DS.Colors.textSecondary)
                }
            case .attempted:
                if let presentation {
                    PickyToolHistoryContentView(presentation: presentation, workingDirectory: workingDirectory)
                }
            case .timing:
                if let startedAt = entry.startedAt {
                    Text(startedAt, format: .dateTime.hour().minute().second())
                        .font(PickyHUDTypography.supportingMonospaced)
                }
                if let duration = entry.durationMs {
                    Text(L10n.t("hud.toolHistory.duration", Int64(duration)))
                        .font(PickyHUDTypography.supportingMonospaced)
                }
                if entry.startedAt == nil && entry.durationMs == nil { status("empty") }
            }
        }
        .padding(DS.Spacing.space2)
        .background(DS.Colors.surface2.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
    }

    private func auxiliaryTitle(_ selected: Auxiliary) -> String {
        switch selected {
        case .arguments: return L10n.t("hud.toolHistory.detail.arguments")
        case .response: return L10n.t("hud.toolHistory.rawResponse")
        case .attempted: return L10n.t("hud.toolHistory.attempted")
        case .timing: return L10n.t("hud.toolHistory.timing")
        }
    }
}
