import AppKit
import SwiftUI

struct PickyToolHistoryEntryView: View {
    let entry: PickyToolHistoryEntry
    var workingDirectory: String? = nil
    var collapseGeneration = 0
    var loadDetail: (() -> PickyToolHistoryDetailModel?)? = nil
    var loadArguments: (() -> PickyToolHistoryDetailModel?)? = nil
    @State private var detail: PickyToolHistoryDetailModel?
    @State private var arguments: PickyToolHistoryDetailModel?
    @State private var expanded: Bool

    init(entry: PickyToolHistoryEntry, workingDirectory: String? = nil, collapseGeneration: Int = 0,
         loadDetail: (() -> PickyToolHistoryDetailModel?)? = nil,
         loadArguments: (() -> PickyToolHistoryDetailModel?)? = nil,
         initiallyExpanded: Bool = false,
         initialDetail: PickyToolHistoryDetailModel? = nil,
         initialArguments: PickyToolHistoryDetailModel? = nil) {
        self.entry = entry
        self.workingDirectory = workingDirectory
        self.collapseGeneration = collapseGeneration
        self.loadDetail = loadDetail
        self.loadArguments = loadArguments
        _expanded = State(initialValue: initiallyExpanded)
        _detail = State(initialValue: initialDetail)
        _arguments = State(initialValue: initialArguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            Button { expanded.toggle() } label: {
                HStack(spacing: DS.Spacing.space2) {
                    PickyToolHistoryStatusIcon(status: entry.status)
                        .frame(width: 16)
                    Text(shortName)
                        .font(PickyHUDTypography.supportingMonospaced)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(width: 52, alignment: .leading)
                    Text(PickyToolHistoryPresentation.title(for: entry))
                        .font(PickyHUDTypography.body)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Spacing.space1)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(PickyHUDTypography.status)
                        .frame(width: PickyHUDTypography.Size.supporting, height: PickyHUDTypography.Size.supporting)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .padding(.horizontal, DS.Spacing.space2)
                .padding(.vertical, DS.Spacing.space2)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
                .background(expanded ? DS.Colors.surface2 : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
            }
            .buttonStyle(PickyToolHistoryQuietButtonStyle())
            .accessibilityValue(L10n.t(expanded ? "hud.toolHistory.result.expanded" : "hud.toolHistory.result.showAll"))
            .help(PickyToolHistoryPresentation.title(for: entry))
            if expanded {
                Group {
                    if let detail, let arguments {
                        PickyToolHistoryDetailView(model: detail, argumentsModel: arguments,
                                                   entry: entry, workingDirectory: workingDirectory)
                            .id(detail.id)
                    } else if loadDetail != nil {
                        ProgressView().controlSize(.small)
                    } else if let result = entry.result {
                        PickyToolHistoryTextBlock(text: result.text)
                    }
                }
                .padding(.leading, DS.Spacing.space8)
                .padding(.trailing, DS.Spacing.space2)
                .padding(.bottom, DS.Spacing.space2)
                .task {
                    if let loadDetail { detail = loadDetail() }
                    if let loadArguments { arguments = loadArguments() }
                }
            }
        }
        .onChange(of: collapseGeneration) { _, _ in expanded = false }
    }

    private var shortName: String {
        switch entry.name.lowercased() {
        case "ask_user_question": return "ask"
        case "todo_write", "todowrite": return "todo"
        default: return entry.name
        }
    }
}

struct PickyToolHistoryStatusIcon: View {
    let status: PickyToolHistoryStatus

    var body: some View {
        Image(systemName: symbol)
            .font(PickyHUDTypography.supportingMedium)
            .foregroundStyle(tint)
            .help(label)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch status {
        case .succeeded: return "checkmark"
        case .failed: return "xmark.circle"
        case .running: return "ellipsis.circle"
        }
    }
    private var tint: Color {
        switch status {
        case .succeeded: return DS.Colors.textSecondary
        case .failed: return DS.Colors.destructiveText
        case .running: return DS.Colors.info
        }
    }
    private var label: String {
        switch status {
        case .succeeded: return L10n.t("hud.conversation.status.completed")
        case .failed: return L10n.t("hud.conversation.status.failed")
        case .running: return L10n.t("hud.conversation.status.running")
        }
    }
}

struct PickyToolHistoryQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration)
    }
    private struct QuietBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(DS.Colors.textSecondary)
                .background(configuration.isPressed ? DS.Colors.surface3 : hovering ? DS.Colors.surface2 : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
                .onHover { hovering = $0 }
        }
    }
}

struct PickyToolHistoryFileLink: View {
    let path: String
    var workingDirectory: String? = nil
    @State private var showsOpenError = false

    private var url: URL? { PickyToolHistoryFilePathPolicy.urlToOpen(for: path, workingDirectory: workingDirectory) }

    var body: some View {
        Group {
            if let url {
                Button { open(url) } label: {
                    Text(path).font(PickyHUDTypography.supportingMonospaced)
                        .foregroundStyle(DS.Colors.accentText)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(PickyToolHistoryQuietButtonStyle())
                .help(L10n.t("hud.toolHistory.file.open.help"))
                .accessibilityLabel(L10n.t("hud.toolHistory.file.open.accessibilityLabel", path))
            } else {
                Text(path).font(PickyHUDTypography.supportingMonospaced)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .contextMenu {
            if let url {
                Button(L10n.t("hud.artifacts.action.open")) { open(url) }
                Button(L10n.t("hud.artifacts.action.reveal")) {
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else { showsOpenError = true }
                }
                Divider()
            }
            Button(L10n.t("hud.toolHistory.file.copyPath")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url?.path ?? path, forType: .string)
            }
        }
        .alert(L10n.t("hud.toolHistory.file.unavailable"), isPresented: $showsOpenError) {
            Button(L10n.t("hud.toolHistory.detail.close"), role: .cancel) {}
        } message: { Text(path) }
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { showsOpenError = true }
    }
}

/// Short outputs size to their content; large outputs remain scrollable rather than expanding the history window.
struct PickyToolHistoryTextBlock: View {
    let text: String
    var tint: Color = DS.Colors.textBody

    private var viewportHeight: CGFloat {
        // Count only enough lines to fill the viewport, not the entire stored result on each redraw.
        var lines = 1
        for character in text where character == "\n" {
            lines += 1
            if lines >= 16 { break }
        }
        let font = NSFont.monospacedSystemFont(ofSize: PickyHUDTypography.Size.supporting, weight: .regular)
        return CGFloat(lines) * ceil(font.ascender - font.descender + font.leading) + DS.Spacing.space4
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text.isEmpty ? L10n.t("hud.toolHistory.detail.empty") : text)
                .font(PickyHUDTypography.supportingMonospaced)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(DS.Spacing.space2)
        }
        .frame(height: viewportHeight)
        .background(DS.Colors.surface2.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
    }
}
