import AppKit
import SwiftUI

struct PickyToolHistoryEntryView: View {
    let entry: PickyToolHistoryEntry
    var workingDirectory: String? = nil
    var collapseGeneration = 0
    /// Shared by every row in a list so titles line up; see `nameColumnWidth(for:fontSize:)`.
    var nameColumnWidth: CGFloat
    var loadDetail: (() -> PickyToolHistoryDetailModel?)? = nil
    var loadArguments: (() -> PickyToolHistoryDetailModel?)? = nil
    @State private var detail: PickyToolHistoryDetailModel?
    @State private var arguments: PickyToolHistoryDetailModel?
    @State private var expanded: Bool

    init(entry: PickyToolHistoryEntry, workingDirectory: String? = nil, collapseGeneration: Int = 0,
         nameColumnWidth: CGFloat? = nil,
         loadDetail: (() -> PickyToolHistoryDetailModel?)? = nil,
         loadArguments: (() -> PickyToolHistoryDetailModel?)? = nil,
         initiallyExpanded: Bool = false,
         initialDetail: PickyToolHistoryDetailModel? = nil,
         initialArguments: PickyToolHistoryDetailModel? = nil) {
        self.entry = entry
        self.workingDirectory = workingDirectory
        self.collapseGeneration = collapseGeneration
        self.nameColumnWidth = nameColumnWidth ?? PickyToolHistoryPresentation.nameColumnWidth(
            for: [PickyToolHistoryPresentation.displayName(for: entry)],
            fontSize: PickyHUDTypography.Size.supporting
        )
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
                        .frame(width: Self.statusColumnWidth)
                    Text(PickyToolHistoryPresentation.displayName(for: entry))
                        .font(PickyHUDTypography.supportingMonospaced)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: nameColumnWidth, alignment: .leading)
                        .help(entry.name)
                    HStack(spacing: DS.Spacing.space2) {
                        Text(PickyToolHistoryPresentation.title(for: entry))
                            .font(PickyHUDTypography.body)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let context = PickyToolHistoryPresentation.context(for: entry) {
                            Text(context)
                                .font(PickyHUDTypography.supporting)
                                .foregroundStyle(DS.Colors.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer(minLength: DS.Spacing.space2)
                    trailingStatus
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(PickyHUDTypography.status)
                        .frame(width: PickyHUDTypography.Size.supporting, height: PickyHUDTypography.Size.supporting)
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .padding(.horizontal, Self.rowHorizontalPadding)
                .padding(.vertical, DS.Spacing.space1)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
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
                .padding(.leading, titleColumnInset)
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

    private static let statusColumnWidth: CGFloat = 16
    private static let rowHorizontalPadding = DS.Spacing.space2

    /// Expanded content starts under the title, not at an arbitrary indent.
    private var titleColumnInset: CGFloat {
        Self.rowHorizontalPadding + Self.statusColumnWidth + DS.Spacing.space2 + nameColumnWidth + DS.Spacing.space2
    }

    @ViewBuilder private var trailingStatus: some View {
        if entry.status == .running {
            Text(L10n.t("hud.conversation.status.running"))
                .font(PickyHUDTypography.status)
                .foregroundStyle(DS.Colors.info)
        } else if let duration = PickyToolHistoryPresentation.durationText(milliseconds: entry.durationMs) {
            Text(duration)
                .font(PickyHUDTypography.supportingMonospaced)
                .foregroundStyle(DS.Colors.textTertiary)
                .help(L10n.t("hud.toolHistory.duration", Int64(entry.durationMs ?? 0)))
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
    /// Optional 2pt leading bar, used to mark a failed command's output without recoloring it.
    var edge: Color? = nil

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
        // A 2-axis ScrollView centers content narrower than the viewport, and an
        // unbounded frame inside it has no width to align to. Pinning the content
        // to at least the viewport width keeps the first column at the leading edge.
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Text(text.isEmpty ? L10n.t("hud.toolHistory.detail.empty") : text)
                    .font(PickyHUDTypography.supportingMonospaced)
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(DS.Spacing.space2)
                    .frame(minWidth: geometry.size.width, alignment: .topLeading)
            }
        }
        .frame(height: viewportHeight)
        .overlay(alignment: .leading) {
            if let edge { Rectangle().fill(edge).frame(width: 2) }
        }
        .background(DS.Colors.surface2.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
    }
}
