import AppKit
import SwiftUI

struct DiffReviewRootView: View {
    @ObservedObject var store: DiffReviewStore

    var body: some View {
        VStack(spacing: 0) {
            DiffReviewGitHubHeaderView(store: store)
            Divider().overlay(Primer.borderDefault)
            HStack(spacing: 0) {
                if store.isSidebarVisible {
                    DiffReviewSidebarView(store: store)
                        .frame(width: 330)
                    Divider().overlay(Primer.borderDefault)
                }
                DiffReviewFilesChangedView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1200, minHeight: 760)
        .background(Primer.canvasDefault)
        .foregroundStyle(Primer.fgDefault)
        .sheet(isPresented: $store.isSubmitReviewPresented) {
            SubmitReviewSheet(store: store)
                .preferredColorScheme(.dark)
        }
    }
}

struct DiffReviewGitHubHeaderView: View {
    @ObservedObject var store: DiffReviewStore

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: { store.isSidebarVisible.toggle() }) {
                Image(systemName: store.isSidebarVisible ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(PrimerIconButtonStyle())
            .help(store.isSidebarVisible ? "Hide file tree" : "Show file tree")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Changed files")
                        .font(.system(size: 17, weight: .semibold))
                    Text(store.snapshot.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Primer.fgMuted)
                        .lineLimit(1)
                    if store.snapshot.files.isEmpty == false {
                        Text("#PLAYGROUND")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Primer.fgSubtle)
                    }
                }
                HStack(spacing: 8) {
                    Text("All changes")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Primer.fgMuted)
                    Text("·")
                        .foregroundStyle(Primer.fgSubtle)
                    Text(store.snapshot.subtitle)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Primer.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !store.snapshot.repoRoot.isEmpty {
                        Text(store.snapshot.repoRoot)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Primer.accentFg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 14)

            Picker("Diff view", selection: $store.viewMode) {
                ForEach(DiffViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 168)

            HStack(spacing: 8) {
                ProgressRingView(progress: viewedProgress)
                    .frame(width: 16, height: 16)
                Text("\(store.viewedFileIDs.count) / \(store.snapshot.files.count) viewed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Primer.fgMuted)
            }

            Button {
                store.isSubmitReviewPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text("Submit review")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .buttonStyle(PrimerButtonStyle(kind: .primary))

            Button(action: { store.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(PrimerIconButtonStyle())
            .help("Refresh")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Primer.canvasDefault)
    }

    private var viewedProgress: Double {
        guard !store.snapshot.files.isEmpty else { return 0 }
        return Double(store.viewedFileIDs.count) / Double(store.snapshot.files.count)
    }
}

struct ProgressRingView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Primer.borderDefault, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(Primer.accentFg, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityLabel("Viewed progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

struct DiffReviewSidebarView: View {
    @ObservedObject var store: DiffReviewStore
    @State private var collapsedDirectoryIDs: Set<String> = []

    private var nodes: [FileTreeNode] {
        FileTreeBuilder().build(files: store.filteredFiles)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Primer.fgSubtle)
                TextField("Filter files…", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Primer.canvasInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Primer.borderDefault, lineWidth: 1))
            .padding(.horizontal, 22)
            .padding(.top, 18)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(nodes) { node in
                        FileTreeRow(
                            store: store,
                            node: node,
                            depth: 0,
                            collapsedDirectoryIDs: $collapsedDirectoryIDs
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
        }
        .background(Primer.canvasDefault)
    }
}

struct FileTreeRow: View {
    @ObservedObject var store: DiffReviewStore
    let node: FileTreeNode
    let depth: Int
    @Binding var collapsedDirectoryIDs: Set<String>

    private var isCollapsed: Bool {
        store.searchText.isEmpty && collapsedDirectoryIDs.contains(node.id)
    }

    private var isSelected: Bool {
        node.file?.id == store.selectedFileID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if let file = node.file {
                    store.select(file)
                } else {
                    toggleDirectory()
                }
            } label: {
                HStack(spacing: 7) {
                    Spacer().frame(width: CGFloat(depth) * 16)
                    if node.file == nil {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Primer.fgMuted)
                            .frame(width: 12)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Primer.fgMuted)
                    } else if let file = node.file {
                        Spacer().frame(width: 12)
                        sidebarFileIcon(file.status)
                    }
                    Text(node.name)
                        .font(.system(size: 14, weight: node.file == nil ? .medium : .regular))
                        .foregroundStyle(isSelected ? Primer.fgDefault : Primer.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let file = node.file {
                        let count = store.commentCount(fileID: file.id)
                        if count > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "bubble")
                                Text("\(count)")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Primer.fgMuted)
                        }
                    }
                }
                .frame(height: 30)
                .padding(.horizontal, 8)
                .background(isSelected ? Primer.neutralMuted.opacity(0.34) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(node.children) { child in
                    FileTreeRow(store: store, node: child, depth: depth + 1, collapsedDirectoryIDs: $collapsedDirectoryIDs)
                }
            }
        }
    }

    private func toggleDirectory() {
        if collapsedDirectoryIDs.contains(node.id) {
            collapsedDirectoryIDs.remove(node.id)
        } else {
            collapsedDirectoryIDs.insert(node.id)
        }
    }
}

struct DiffReviewFilesChangedView: View {
    @ObservedObject var store: DiffReviewStore

    var body: some View {
        AppKitDiffFilesChangedView(store: store)
            .background(Primer.canvasDefault)
    }
}

struct DiffFileCard: View {
    @ObservedObject var store: DiffReviewStore
    let file: DiffFile

    private var isSelected: Bool { store.selectedFileID == file.id }
    private var isCollapsed: Bool { store.collapsedFileIDs.contains(file.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DiffFileCardHeader(store: store, file: file)
            if !isCollapsed {
                Divider().overlay(Primer.borderMuted)
                DiffFileContent(store: store, file: file)
            }
        }
        .background(Primer.canvasDefault)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Primer.accentEmphasis : Primer.borderDefault, lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: isSelected ? Primer.accentEmphasis.opacity(0.18) : .clear, radius: 10, x: 0, y: 0)
        .onTapGesture { store.select(file) }
    }
}

struct DiffFileCardHeader: View {
    @ObservedObject var store: DiffReviewStore
    let file: DiffFile

    private var isCollapsed: Bool { store.collapsedFileIDs.contains(file.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    store.toggleCollapsed(fileID: file.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Primer.fgMuted)
                        Text(file.displayPath)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Primer.fgDefault)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.trailing, 6)
                    .frame(minHeight: 40, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .help(isCollapsed ? "Expand file" : "Collapse file")

                Button {
                    copyToPasteboard(file.newPath ?? file.oldPath ?? file.displayPath)
                    store.statusMessage = "Copied path"
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Primer.fgMuted)
                .help("Copy path")

                Button {
                    openFile(file, repoRoot: store.snapshot.repoRoot)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Primer.fgMuted)
                .help("Open file")

                Spacer(minLength: 8)

                DiffStatMiniView(insertions: file.insertions, deletions: file.deletions)

                Button {
                    store.toggleViewed(fileID: file.id)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: store.viewedFileIDs.contains(file.id) ? "checkmark.square.fill" : "square")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Viewed")
                    }
                    .padding(.horizontal, 2)
                }
                .buttonStyle(PrimerButtonStyle(kind: .secondary))

                Button {
                    store.beginComment(target: .file(fileID: file.id))
                } label: {
                    Image(systemName: "bubble")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(PrimerIconButtonStyle(borderless: true))
                .help("Add file comment")
            }
            .padding(.horizontal, 14)
            .frame(height: 52)

            let target = DiffCommentTarget.file(fileID: file.id)
            if store.activeCommentTarget == target || !store.comments(for: target).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.comments(for: target)) { comment in
                        SavedCommentView(comment: comment)
                    }
                    if store.activeCommentTarget == target {
                        CommentDraftView(store: store)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(Primer.canvasSubtle)
    }
}

struct DiffFileContent: View {
    @ObservedObject var store: DiffReviewStore
    let file: DiffFile

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(file.metadataLines.filter(shouldShowMetadataLine), id: \.self) { line in
                MetadataLineView(text: line, mode: store.viewMode)
            }
            if file.isBinary && file.hunks.isEmpty {
                BinaryPlaceholderView()
            }
            switch store.viewMode {
            case .unified:
                ForEach(renderedUnifiedHunks) { rendered in
                    HunkHeaderView(hunk: rendered.hunk, mode: store.viewMode)
                    ForEach(rendered.lines) { line in
                        UnifiedDiffLineRow(store: store, file: file, line: line)
                    }
                }
            case .split:
                ForEach(renderedSplitHunks) { rendered in
                    HunkHeaderView(hunk: rendered.hunk, mode: store.viewMode)
                    ForEach(rendered.rows) { row in
                        SplitDiffRowView(store: store, file: file, row: row)
                    }
                }
            }
            if isLargeDiff {
                LargeDiffFooterView(
                    totalRows: totalRows,
                    visibleRows: min(totalRows, renderLimit),
                    isExpanded: store.isLargeDiffExpanded(fileID: file.id),
                    action: { store.toggleLargeDiffExpanded(fileID: file.id) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let previewRowLimit = 180

    private var renderLimit: Int {
        store.isLargeDiffExpanded(fileID: file.id) ? Int.max : Self.previewRowLimit
    }

    private var totalRows: Int {
        switch store.viewMode {
        case .unified:
            return file.hunks.reduce(0) { $0 + $1.lines.count }
        case .split:
            return file.hunks.reduce(0) { $0 + $1.splitRows.count }
        }
    }

    private var isLargeDiff: Bool {
        totalRows > Self.previewRowLimit
    }

    private var renderedUnifiedHunks: [RenderedUnifiedHunk] {
        var remaining = renderLimit
        var result: [RenderedUnifiedHunk] = []
        for hunk in file.hunks {
            guard remaining > 0 else { break }
            let lines = Array(hunk.lines.prefix(remaining))
            guard !lines.isEmpty else { continue }
            result.append(RenderedUnifiedHunk(hunk: hunk, lines: lines))
            remaining -= lines.count
        }
        return result
    }

    private var renderedSplitHunks: [RenderedSplitHunk] {
        var remaining = renderLimit
        var result: [RenderedSplitHunk] = []
        for hunk in file.hunks {
            guard remaining > 0 else { break }
            let rows = Array(hunk.splitRows.prefix(remaining))
            guard !rows.isEmpty else { continue }
            result.append(RenderedSplitHunk(hunk: hunk, rows: rows))
            remaining -= rows.count
        }
        return result
    }

    private func shouldShowMetadataLine(_ line: String) -> Bool {
        !(line.hasPrefix("diff --git ") || line.hasPrefix("--- ") || line.hasPrefix("+++ "))
    }
}

private struct RenderedUnifiedHunk: Identifiable {
    var id: String { hunk.id }
    let hunk: DiffHunk
    let lines: [DiffLine]
}

private struct RenderedSplitHunk: Identifiable {
    var id: String { hunk.id }
    let hunk: DiffHunk
    let rows: [SplitDiffRow]
}

private enum DiffLayout {
    static let comment: CGFloat = 22
    static let lineNumber: CGFloat = 32
    static let unifiedGutter = comment + lineNumber + lineNumber
    static let splitGutter = comment + lineNumber
}

struct UnifiedDiffLineRow: View {
    @ObservedObject var store: DiffReviewStore
    let file: DiffFile
    let line: DiffLine
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                CommentButtonColumn(target: target, isHovered: isHovered, store: store)
                lineNumber(line.oldNumber, isActive: line.kind == .deletion)
                lineNumber(line.newNumber, isActive: line.kind == .addition)
                CodeTextView(text: line.text.isEmpty ? " " : line.text, filePath: filePath, baseColor: textColor)
                    .lineLimit(store.wrapLines ? nil : 1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .background(background)
            .onHover { isHovered = $0 }

            commentThread(target: target, leading: DiffLayout.unifiedGutter)
        }
    }

    private var filePath: String { file.newPath ?? file.oldPath ?? file.displayPath }
    private var target: DiffCommentTarget? { line.kind == .metadata ? nil : .line(fileID: file.id, line: line) }
    private var background: Color { rowBackground(line.kind, isHovered: isHovered) }
    private var textColor: Color { rowTextColor(line.kind) }

    private func lineNumber(_ value: Int?, isActive: Bool) -> some View {
        Text(value.map(String.init) ?? "")
            .font(codeFont(weight: .regular, size: 12))
            .foregroundStyle(isActive ? Primer.fgDefault : Primer.fgSubtle)
            .frame(width: DiffLayout.lineNumber, alignment: .trailing)
            .padding(.trailing, 6)
            .background(isActive ? activeLineNumberBackground : Color.clear)
            .textSelection(.enabled)
    }

    private var activeLineNumberBackground: Color {
        switch line.kind {
        case .addition: Primer.successMuted
        case .deletion: Primer.dangerMuted
        default: Color.clear
        }
    }

    @ViewBuilder
    private func commentThread(target: DiffCommentTarget?, leading: CGFloat) -> some View {
        if let target {
            ForEach(store.comments(for: target)) { comment in
                SavedCommentView(comment: comment)
                    .padding(.leading, leading)
                    .padding(.trailing, 14)
                    .padding(.vertical, 5)
            }
            if store.activeCommentTarget == target {
                CommentDraftView(store: store)
                    .padding(.leading, leading)
                    .padding(.trailing, 14)
                    .padding(.vertical, 8)
            }
        }
    }
}

struct SplitDiffRowView: View {
    @ObservedObject var store: DiffReviewStore
    let file: DiffFile
    let row: SplitDiffRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                SplitDiffCell(store: store, file: file, line: row.oldLine, side: .original)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Primer.borderMuted).frame(width: 1)
                SplitDiffCell(store: store, file: file, line: row.newLine, side: .modified)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            splitCommentThread(line: row.oldLine, leading: DiffLayout.splitGutter)
            splitCommentThread(line: row.newLine, leading: DiffLayout.splitGutter)
        }
    }

    @ViewBuilder
    private func splitCommentThread(line: DiffLine?, leading: CGFloat) -> some View {
        if let line, line.kind != .metadata {
            let target = DiffCommentTarget.line(fileID: file.id, line: line)
            ForEach(store.comments(for: target)) { comment in
                SavedCommentView(comment: comment)
                    .padding(.leading, leading)
                    .padding(.trailing, 14)
                    .padding(.vertical, 5)
            }
            if store.activeCommentTarget == target {
                CommentDraftView(store: store)
                    .padding(.leading, leading)
                    .padding(.trailing, 14)
                    .padding(.vertical, 8)
            }
        }
    }
}

struct SplitDiffCell: View {
    @ObservedObject var store: DiffReviewStore
    let file: DiffFile
    let line: DiffLine?
    let side: DiffCommentTarget.Side
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            CommentButtonColumn(target: target, isHovered: isHovered, store: store)
            Text(lineNumberText)
                .font(codeFont(weight: .regular, size: 12))
                .foregroundStyle(activeNumber ? Primer.fgDefault : Primer.fgSubtle)
                .frame(width: DiffLayout.lineNumber, alignment: .trailing)
                .padding(.trailing, 6)
                .background(activeNumber ? activeLineNumberBackground : Color.clear)
            CodeTextView(text: codeText, filePath: filePath, baseColor: codeColor)
                .lineLimit(store.wrapLines ? nil : 1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)
        }
        .padding(.vertical, 1)
        .background(background)
        .onHover { isHovered = $0 }
    }

    private var filePath: String { file.newPath ?? file.oldPath ?? file.displayPath }
    private var target: DiffCommentTarget? {
        guard let line, line.kind != .metadata else { return nil }
        return DiffCommentTarget.line(fileID: file.id, line: line)
    }
    private var activeNumber: Bool {
        guard let line else { return false }
        return line.kind == .addition || line.kind == .deletion
    }
    private var lineNumberText: String {
        guard let line else { return "" }
        switch side {
        case .original: return line.oldNumber.map(String.init) ?? ""
        case .modified, .file: return line.newNumber.map(String.init) ?? ""
        }
    }
    private var codeText: String {
        guard let line else { return " " }
        return line.text.isEmpty ? " " : line.text
    }
    private var codeColor: Color { line.map { rowTextColor($0.kind) } ?? Primer.fgSubtle }
    private var background: Color { line.map { rowBackground($0.kind, isHovered: isHovered) } ?? Primer.canvasDefault }
    private var activeLineNumberBackground: Color {
        guard let line else { return Color.clear }
        switch line.kind {
        case .addition: return Primer.successMuted
        case .deletion: return Primer.dangerMuted
        default: return Color.clear
        }
    }
}

private struct CommentButtonColumn: View {
    let target: DiffCommentTarget?
    let isHovered: Bool
    @ObservedObject var store: DiffReviewStore

    var body: some View {
        ZStack {
            if let target, isHovered || !store.comments(for: target).isEmpty {
                Button {
                    store.beginComment(target: target)
                } label: {
                    Image(systemName: "bubble")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Primer.accentEmphasis))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Add comment")
            }
        }
        .frame(width: DiffLayout.comment)
    }
}

private func rowBackground(_ kind: DiffLineKind, isHovered: Bool) -> Color {
    switch kind {
    case .addition: Primer.successSubtle
    case .deletion: Primer.dangerSubtle
    case .metadata: Primer.canvasSubtle
    case .context: isHovered ? Primer.neutralMuted.opacity(0.26) : Primer.canvasDefault
    }
}

private func rowTextColor(_ kind: DiffLineKind) -> Color {
    switch kind {
    case .addition: Primer.successText
    case .deletion: Primer.dangerText
    case .metadata: Primer.fgSubtle
    case .context: Primer.fgDefault
    }
}

struct HunkHeaderView: View {
    let hunk: DiffHunk
    let mode: DiffViewMode

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: mode == .unified ? DiffLayout.unifiedGutter : DiffLayout.splitGutter)
            Text(hunk.header)
                .font(codeFont(weight: .semibold, size: 12))
                .foregroundStyle(Primer.accentFg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
        }
        .background(Primer.accentMuted)
    }
}

struct MetadataLineView: View {
    let text: String
    let mode: DiffViewMode

    var body: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: mode == .unified ? DiffLayout.unifiedGutter : DiffLayout.splitGutter)
            Text(text)
                .font(codeFont(weight: .regular, size: 12))
                .foregroundStyle(Primer.fgSubtle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .background(Primer.canvasDefault)
    }
}

struct LargeDiffFooterView: View {
    let totalRows: Int
    let visibleRows: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal")
                .foregroundStyle(Primer.attentionFg)
            Text(isExpanded ? "Showing all \(totalRows) diff rows." : "Showing \(visibleRows) of \(totalRows) diff rows for performance.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Primer.fgMuted)
            Spacer()
            Button(isExpanded ? "Collapse preview" : "Show full diff", action: action)
                .buttonStyle(PrimerButtonStyle(kind: .secondary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Primer.canvasSubtle)
        .overlay(alignment: .top) { Rectangle().fill(Primer.borderMuted).frame(height: 1) }
    }
}

struct BinaryPlaceholderView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
            Text("Binary file changed. Text diff is unavailable in this playground.")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Primer.fgMuted)
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(Primer.canvasSubtle)
    }
}

struct CommentDraftView: View {
    @ObservedObject var store: DiffReviewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $store.draftComment)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(9)
                .frame(height: 96)
                .background(Primer.canvasInset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Primer.borderDefault, lineWidth: 1))
            HStack {
                Spacer()
                Button("Cancel") { store.cancelComment() }
                    .buttonStyle(PrimerButtonStyle(kind: .secondary))
                Button("Add comment") { store.saveDraftComment() }
                    .buttonStyle(PrimerButtonStyle(kind: .primary))
                    .disabled(store.draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(Primer.canvasSubtle, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Primer.borderMuted, lineWidth: 1))
    }
}

struct SavedCommentView: View {
    let comment: DiffReviewComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(Primer.accentFg)
                Text("Review comment")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Primer.fgMuted)
                Spacer()
            }
            Text(comment.body)
                .font(.system(size: 13))
                .foregroundStyle(Primer.fgDefault)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Primer.canvasSubtle, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Primer.borderMuted, lineWidth: 1))
    }
}

struct SubmitReviewSheet: View {
    @ObservedObject var store: DiffReviewStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Submit review")
                        .font(.system(size: 18, weight: .semibold))
                    Text("\(store.comments.count) line/file comments · \(store.viewedFileIDs.count) / \(store.snapshot.files.count) viewed")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Primer.fgMuted)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(PrimerIconButtonStyle(borderless: true))
            }
            .padding(18)
            Divider().overlay(Primer.borderDefault)

            VStack(alignment: .leading, spacing: 12) {
                Text("Overall feedback")
                    .font(.system(size: 13, weight: .semibold))
                TextEditor(text: $store.overallComment)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 150)
                    .background(Primer.canvasInset, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Primer.borderDefault, lineWidth: 1))

                Text("Prompt preview")
                    .font(.system(size: 13, weight: .semibold))
                ScrollView {
                    Text(store.feedbackPrompt().isEmpty ? "Add an overall comment or line comments to generate feedback." : store.feedbackPrompt())
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Primer.fgMuted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 180)
                .background(Primer.canvasInset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Primer.borderMuted, lineWidth: 1))
            }
            .padding(18)

            Spacer(minLength: 0)
            Divider().overlay(Primer.borderDefault)
            HStack {
                if let status = store.statusMessage {
                    Text(status)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Primer.fgMuted)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PrimerButtonStyle(kind: .secondary))
                Button("Copy feedback prompt") {
                    store.copyFeedbackPrompt()
                    dismiss()
                }
                .buttonStyle(PrimerButtonStyle(kind: .primary))
                .disabled(!store.hasFeedback)
            }
            .padding(18)
        }
        .frame(width: 680, height: 620)
        .background(Primer.canvasDefault)
        .foregroundStyle(Primer.fgDefault)
    }
}

struct EmptyFilesView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
            Text("No files match your filter")
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(Primer.fgSubtle)
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

struct CodeTextView: View {
    let text: String
    let filePath: String
    let baseColor: Color

    var body: some View {
        // Keep the playground fast while iterating on layout. Syntax highlighting can be
        // reintroduced later with a cached TextKit/AttributedString renderer.
        Text(text)
            .font(codeFont())
            .foregroundStyle(baseColor)
    }
}

enum CodeHighlighter {
    static func highlight(text: String, filePath: String, baseColor: Color) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = baseColor

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
            attributed.foregroundColor = Primer.fgSubtle
            return attributed
        }

        let keywords = keywordSet(filePath: filePath)
        guard !keywords.isEmpty else { return attributed }
        let nsText = text as NSString
        let pattern = #"\b([A-Za-z_][A-Za-z0-9_]*)\b|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributed }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            guard let range = Range(match.range, in: attributed) else { continue }
            let token = nsText.substring(with: match.range)
            if token.hasPrefix("\"") || token.hasPrefix("'") {
                attributed[range].foregroundColor = Primer.doneFg
            } else if keywords.contains(token) {
                attributed[range].foregroundColor = Primer.prettylightsSyntaxKeyword
            }
        }
        return attributed
    }

    private static func keywordSet(filePath: String) -> Set<String> {
        let lower = filePath.lowercased()
        if lower.hasSuffix(".swift") {
            return ["import", "struct", "class", "enum", "func", "let", "var", "private", "public", "return", "if", "else", "switch", "case", "guard", "for", "while", "in", "extension", "protocol", "some", "View"]
        }
        if lower.hasSuffix(".ts") || lower.hasSuffix(".tsx") || lower.hasSuffix(".js") || lower.hasSuffix(".jsx") {
            return ["import", "from", "export", "const", "let", "var", "function", "return", "if", "else", "switch", "case", "interface", "type", "class", "extends", "async", "await", "private", "public"]
        }
        return []
    }
}

struct DiffStatMiniView: View {
    let insertions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            if insertions > 0 {
                Text("+\(formattedCount(insertions))")
                    .foregroundStyle(Primer.successFg)
            }
            if deletions > 0 {
                Text("-\(formattedCount(deletions))")
                    .foregroundStyle(Primer.dangerFg)
            }
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(squareColor(index: index))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
    }

    private func squareColor(index: Int) -> Color {
        let segments = diffStatSegments
        if index < segments.insertions { return Primer.successFg.opacity(0.85) }
        if index < segments.insertions + segments.deletions { return Primer.dangerFg.opacity(0.85) }
        return Primer.neutralMuted
    }

    private var diffStatSegments: (insertions: Int, deletions: Int) {
        let total = insertions + deletions
        guard total > 0 else { return (0, 0) }

        var green = insertions > 0 ? max(1, Int((Double(insertions) / Double(total) * 5.0).rounded())) : 0
        var red = deletions > 0 ? max(1, 5 - green) : 0

        if insertions == 0 { red = min(5, red) }
        if deletions == 0 { green = min(5, green) }
        if green + red > 5 {
            if green > red {
                green = 5 - red
            } else {
                red = 5 - green
            }
        }
        return (green, red)
    }
}

@ViewBuilder
func sidebarFileIcon(_ status: DiffFileStatus) -> some View {
    Image(systemName: status == .deleted ? "doc" : "doc.badge.plus")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(statusColor(status))
        .frame(width: 16)
}

func statusColor(_ status: DiffFileStatus) -> Color {
    switch status {
    case .added: Primer.successFg
    case .deleted: Primer.dangerFg
    case .renamed, .copied: Primer.accentFg
    case .modified: Primer.attentionFg
    case .unknown: Primer.fgSubtle
    }
}

func codeFont(weight: Font.Weight = .regular, size: CGFloat = 12.5) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func openFile(_ file: DiffFile, repoRoot: String) {
    let path = file.newPath ?? file.oldPath ?? file.displayPath
    guard !path.isEmpty else { return }
    let basePath = repoRoot.isEmpty ? FileManager.default.currentDirectoryPath : repoRoot
    let url = path.hasPrefix("/")
        ? URL(fileURLWithPath: path)
        : URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: basePath))
    let absoluteURL = url.standardizedFileURL
    if FileManager.default.fileExists(atPath: absoluteURL.path) {
        NSWorkspace.shared.open(absoluteURL)
    } else {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

func formattedCount(_ count: Int) -> String {
    count.formatted(.number.grouping(.automatic))
}

struct FileTreeNode: Identifiable, Equatable {
    let id: String
    let name: String
    let children: [FileTreeNode]
    let file: DiffFile?
}

struct FileTreeBuilder {
    func build(files: [DiffFile]) -> [FileTreeNode] {
        let root = MutableTreeNode(name: "", path: "")
        for file in files {
            let path = treePath(for: file)
            let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            var node = root
            for (index, part) in parts.enumerated() {
                let childPath = node.path.isEmpty ? part : "\(node.path)/\(part)"
                let child = node.children[part] ?? MutableTreeNode(name: part, path: childPath)
                node.children[part] = child
                node = child
                if index == parts.count - 1 { node.file = file }
            }
        }
        return root.snapshotChildren()
    }

    private func treePath(for file: DiffFile) -> String {
        file.newPath ?? file.oldPath ?? file.displayPath.replacingOccurrences(of: " → ", with: "/")
    }

    private final class MutableTreeNode {
        let name: String
        let path: String
        var children: [String: MutableTreeNode] = [:]
        var file: DiffFile?

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func snapshotChildren() -> [FileTreeNode] {
            children.values
                .map { child in
                    FileTreeNode(id: child.path, name: child.name, children: child.snapshotChildren(), file: child.file)
                }
                .sorted { lhs, rhs in
                    if (lhs.file == nil) != (rhs.file == nil) { return lhs.file == nil }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
        }
    }
}

struct PrimerButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(background(configuration), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }

    private var foreground: Color { kind == .primary ? .white : Primer.fgDefault }
    private var border: Color { kind == .primary ? Primer.successEmphasis : Primer.borderDefault }
    private func background(_ configuration: Configuration) -> Color {
        switch kind {
        case .primary: configuration.isPressed ? Primer.successEmphasis.opacity(0.85) : Primer.successEmphasis
        case .secondary: configuration.isPressed ? Primer.neutralMuted.opacity(0.7) : Primer.btnBg
        }
    }
}

struct PrimerIconButtonStyle: ButtonStyle {
    var borderless = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Primer.fgMuted)
            .frame(width: 34, height: 34)
            .background(configuration.isPressed ? Primer.neutralMuted.opacity(0.65) : (borderless ? Color.clear : Primer.btnBg), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderless ? Color.clear : Primer.borderDefault, lineWidth: 1))
    }
}

enum Primer {
    // GitHub Primer dark-like primitives.
    static let canvasDefault = Color(hex: "#0d1117")
    static let canvasSubtle = Color(hex: "#161b22")
    static let canvasInset = Color(hex: "#010409")
    static let borderDefault = Color(hex: "#30363d")
    static let borderMuted = Color(hex: "#21262d")
    static let fgDefault = Color(hex: "#e6edf3")
    static let fgMuted = Color(hex: "#8b949e")
    static let fgSubtle = Color(hex: "#6e7681")
    static let accentFg = Color(hex: "#58a6ff")
    static let accentEmphasis = Color(hex: "#1f6feb")
    static let accentMuted = Color(hex: "#1f6feb").opacity(0.18)
    static let successFg = Color(hex: "#3fb950")
    static let successText = Color(hex: "#d1f8d7")
    static let successSubtle = Color(hex: "#0f2f1d")
    static let successMuted = Color(hex: "#238636").opacity(0.45)
    static let successEmphasis = Color(hex: "#238636")
    static let dangerFg = Color(hex: "#f85149")
    static let dangerText = Color(hex: "#ffdcd7")
    static let dangerSubtle = Color(hex: "#3b1518")
    static let dangerMuted = Color(hex: "#da3633").opacity(0.45)
    static let attentionFg = Color(hex: "#d29922")
    static let doneFg = Color(hex: "#a5d6ff")
    static let neutralMuted = Color(hex: "#6e7681").opacity(0.28)
    static let btnBg = Color(hex: "#21262d")
    static let prettylightsSyntaxKeyword = Color(hex: "#ff7b72")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xff, (int >> 8) & 0xff, int & 0xff)
        default:
            (r, g, b) = (255, 255, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}
