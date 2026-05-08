import AppKit
import SwiftUI

final class DiffReviewTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextView || responder is NSTextField || responder is NSButton {
            return true
        }
        if let view = responder as? NSView, containsEditableDescendant(view) {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    private func containsEditableDescendant(_ view: NSView) -> Bool {
        if view is NSTextView || view is NSTextField || view is NSButton {
            return true
        }
        return view.subviews.contains { containsEditableDescendant($0) }
    }
}

struct AppKitDiffFilesChangedView: NSViewRepresentable {
    @ObservedObject var store: DiffReviewStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSPrimer.canvasDefault
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = DiffReviewTableView()
        tableView.headerView = nil
        tableView.backgroundColor = NSPrimer.canvasDefault
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = .zero
        tableView.rowSizeStyle = .custom
        tableView.allowsColumnResizing = false
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main-diff-column"))
        column.resizingMask = NSTableColumn.ResizingOptions.autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        context.coordinator.scrollView = scrollView
        context.coordinator.tableView = tableView
        context.coordinator.rebuildRows()
        context.coordinator.syncColumnWidth()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.store = store
        context.coordinator.rebuildRows()
        context.coordinator.syncColumnWidth()
        context.coordinator.tableView?.reloadData()
        context.coordinator.scrollToSelectedIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var store: DiffReviewStore
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        private var rows: [DiffTableRow] = []
        private var lastScrolledSelectedID: String?
        private let highlighter = AppKitSyntaxHighlighter()

        init(store: DiffReviewStore) {
            self.store = store
        }

        func rebuildRows() {
            rows = DiffTableRowBuilder.rows(for: store)
        }

        func syncColumnWidth() {
            guard let tableView, let scrollView, let column = tableView.tableColumns.first else { return }
            let width = max(600, scrollView.contentView.bounds.width)
            if abs(column.width - width) > 0.5 {
                column.width = width
                tableView.frame.size.width = width
            }
        }

        func scrollToSelectedIfNeeded() {
            guard let selectedID = store.selectedFileID, selectedID != lastScrolledSelectedID else { return }
            guard let tableView, let rowIndex = rows.firstIndex(where: { $0.fileID == selectedID && $0.isFileHeader }) else { return }
            lastScrolledSelectedID = selectedID
            tableView.scrollRowToVisible(rowIndex)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 24 }
            return height(for: rows[row], tableWidth: tableView.bounds.width)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let rowModel = rows[row]
            switch rowModel {
            case .empty:
                return EmptyDiffCellView()
            case .fileHeader(let file):
                return FileHeaderCellView(
                    file: file,
                    isSelected: store.selectedFileID == file.id,
                    isCollapsed: store.collapsedFileIDs.contains(file.id),
                    isViewed: store.viewedFileIDs.contains(file.id),
                    commentCount: store.commentCount(fileID: file.id),
                    repoRoot: store.snapshot.repoRoot,
                    onSelect: { [weak self] in self?.store.select(file) },
                    onToggleCollapse: { [weak self] in self?.store.toggleCollapsed(fileID: file.id) },
                    onToggleViewed: { [weak self] in self?.store.toggleViewed(fileID: file.id) },
                    onComment: { [weak self] in self?.store.beginComment(target: .file(fileID: file.id)) }
                )
            case .fileComment(_, let comment), .lineComment(_, _, let comment):
                return SavedCommentCellView(comment: comment)
            case .fileCommentEditor:
                return CommentEditorCellView(
                    draft: store.draftComment,
                    onSave: { [weak self] text in
                        self?.store.draftComment = text
                        self?.store.saveDraftComment()
                    },
                    onCancel: { [weak self] in self?.store.cancelComment() }
                )
            case .lineCommentEditor:
                return CommentEditorCellView(
                    draft: store.draftComment,
                    onSave: { [weak self] text in
                        self?.store.draftComment = text
                        self?.store.saveDraftComment()
                    },
                    onCancel: { [weak self] in self?.store.cancelComment() }
                )
            case .metadata(_, let text, let mode):
                return MetadataDiffCellView(text: text, mode: mode)
            case .hunk(_, let hunk, let mode):
                return HunkDiffCellView(hunk: hunk, mode: mode)
            case .unifiedLine(let file, let line):
                let target = DiffCommentTarget.line(fileID: file.id, line: line)
                return UnifiedLineCellView(
                    file: file,
                    line: line,
                    wrapLines: store.wrapLines,
                    commentsCount: store.comments(for: target).count,
                    highlighter: highlighter,
                    onSelectFile: { [weak self] in self?.store.select(file) },
                    onComment: { [weak self] in self?.store.beginComment(target: target) }
                )
            case .splitLine(let file, let splitRow):
                return SplitLineCellView(
                    file: file,
                    row: splitRow,
                    wrapLines: store.wrapLines,
                    commentsCount: commentsCount(for: file.id, splitRow: splitRow),
                    highlighter: highlighter,
                    onSelectFile: { [weak self] in self?.store.select(file) },
                    onComment: { [weak self] target in self?.store.beginComment(target: target) }
                )
            case .largeFooter(let file, let totalRows, let visibleRows, let isExpanded):
                return LargeDiffFooterCellView(
                    totalRows: totalRows,
                    visibleRows: visibleRows,
                    isExpanded: isExpanded,
                    onToggle: { [weak self] in self?.store.toggleLargeDiffExpanded(fileID: file.id) }
                )
            }
        }

        private func commentsCount(for fileID: String, splitRow: SplitDiffRow) -> Int {
            var count = 0
            if let oldLine = splitRow.oldLine, oldLine.kind != .metadata {
                count += store.comments(for: DiffCommentTarget.line(fileID: fileID, line: oldLine)).count
            }
            if let newLine = splitRow.newLine, newLine.kind != .metadata, newLine.id != splitRow.oldLine?.id {
                count += store.comments(for: DiffCommentTarget.line(fileID: fileID, line: newLine)).count
            }
            return count
        }

        private func height(for row: DiffTableRow, tableWidth: CGFloat) -> CGFloat {
            switch row {
            case .empty:
                return 360
            case .fileHeader:
                return 58
            case .fileComment, .lineComment:
                return 58
            case .fileCommentEditor, .lineCommentEditor:
                return 138
            case .metadata:
                return 22
            case .hunk:
                return 31
            case .largeFooter:
                return 48
            case .unifiedLine(let file, let line):
                guard store.wrapLines else { return 22 }
                let gutter = DiffTableLayout.outerLeading + DiffTableLayout.outerTrailing + DiffTableLayout.unifiedGutter + 10
                let width = max(80, tableWidth - gutter)
                return measuredCodeHeight(text: line.text, filePath: filePath(file), kind: line.kind, width: width)
            case .splitLine(let file, let row):
                guard store.wrapLines else { return 22 }
                let halfWidth = max(80, (tableWidth - DiffTableLayout.outerLeading - DiffTableLayout.outerTrailing - 1) / 2 - DiffTableLayout.splitGutter - 10)
                let oldHeight = row.oldLine.map { measuredCodeHeight(text: $0.text, filePath: filePath(file), kind: $0.kind, width: halfWidth) } ?? 22
                let newHeight = row.newLine.map { measuredCodeHeight(text: $0.text, filePath: filePath(file), kind: $0.kind, width: halfWidth) } ?? 22
                return max(oldHeight, newHeight)
            }
        }

        private func measuredCodeHeight(text: String, filePath: String, kind: DiffLineKind, width: CGFloat) -> CGFloat {
            let color = NSDiffColors.rowTextColor(kind)
            let attributed = highlighter.highlight(text: text.isEmpty ? " " : text, filePath: filePath, baseColor: color)
            let rect = attributed.boundingRect(
                with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            return max(22, ceil(rect.height) + 4)
        }

        private func filePath(_ file: DiffFile) -> String {
            file.newPath ?? file.oldPath ?? file.displayPath
        }
    }
}

private enum DiffTableRow {
    case empty
    case fileHeader(DiffFile)
    case fileComment(DiffFile, DiffReviewComment)
    case fileCommentEditor(DiffFile)
    case metadata(fileID: String, text: String, mode: DiffViewMode)
    case hunk(fileID: String, hunk: DiffHunk, mode: DiffViewMode)
    case unifiedLine(file: DiffFile, line: DiffLine)
    case splitLine(file: DiffFile, row: SplitDiffRow)
    case lineComment(fileID: String, target: DiffCommentTarget, comment: DiffReviewComment)
    case lineCommentEditor(fileID: String, target: DiffCommentTarget)
    case largeFooter(file: DiffFile, totalRows: Int, visibleRows: Int, isExpanded: Bool)

    var fileID: String? {
        switch self {
        case .empty: return nil
        case .fileHeader(let file), .fileComment(let file, _), .fileCommentEditor(let file), .largeFooter(let file, _, _, _): return file.id
        case .metadata(let fileID, _, _), .hunk(let fileID, _, _), .lineComment(let fileID, _, _), .lineCommentEditor(let fileID, _): return fileID
        case .unifiedLine(let file, _), .splitLine(let file, _): return file.id
        }
    }

    var isFileHeader: Bool {
        if case .fileHeader = self { return true }
        return false
    }
}

private enum DiffTableRowBuilder {
    static let previewRowLimit = 180

    @MainActor
    static func rows(for store: DiffReviewStore) -> [DiffTableRow] {
        let files = store.filteredFiles
        guard !files.isEmpty else { return [.empty] }

        var rows: [DiffTableRow] = []
        for file in files {
            rows.append(.fileHeader(file))
            appendCommentRows(target: .file(fileID: file.id), file: file, rows: &rows, store: store)

            guard !store.collapsedFileIDs.contains(file.id) else { continue }

            for line in file.metadataLines where shouldShowMetadataLine(line) {
                rows.append(.metadata(fileID: file.id, text: line, mode: store.viewMode))
            }

            let totalRows = rowCount(file: file, mode: store.viewMode)
            let limit = store.isLargeDiffExpanded(fileID: file.id) ? Int.max : previewRowLimit
            var remaining = limit

            for hunk in file.hunks {
                guard remaining > 0 else { break }
                switch store.viewMode {
                case .unified:
                    let visibleLines = Array(hunk.lines.prefix(remaining))
                    guard !visibleLines.isEmpty else { continue }
                    rows.append(.hunk(fileID: file.id, hunk: hunk, mode: store.viewMode))
                    for line in visibleLines {
                        rows.append(.unifiedLine(file: file, line: line))
                        appendLineCommentRows(fileID: file.id, line: line, rows: &rows, store: store)
                    }
                    remaining -= visibleLines.count
                case .split:
                    let splitRows = Array(hunk.splitRows.prefix(remaining))
                    guard !splitRows.isEmpty else { continue }
                    rows.append(.hunk(fileID: file.id, hunk: hunk, mode: store.viewMode))
                    for splitRow in splitRows {
                        rows.append(.splitLine(file: file, row: splitRow))
                        if let oldLine = splitRow.oldLine { appendLineCommentRows(fileID: file.id, line: oldLine, rows: &rows, store: store) }
                        if let newLine = splitRow.newLine, newLine.id != splitRow.oldLine?.id { appendLineCommentRows(fileID: file.id, line: newLine, rows: &rows, store: store) }
                    }
                    remaining -= splitRows.count
                }
            }

            if totalRows > previewRowLimit {
                rows.append(.largeFooter(
                    file: file,
                    totalRows: totalRows,
                    visibleRows: min(totalRows, limit),
                    isExpanded: store.isLargeDiffExpanded(fileID: file.id)
                ))
            }
        }
        return rows
    }

    private static func shouldShowMetadataLine(_ line: String) -> Bool {
        !(line.hasPrefix("diff --git ") || line.hasPrefix("--- ") || line.hasPrefix("+++ "))
    }

    private static func rowCount(file: DiffFile, mode: DiffViewMode) -> Int {
        switch mode {
        case .unified:
            return file.hunks.reduce(0) { $0 + $1.lines.count }
        case .split:
            return file.hunks.reduce(0) { $0 + $1.splitRows.count }
        }
    }

    @MainActor
    private static func appendCommentRows(target: DiffCommentTarget, file: DiffFile, rows: inout [DiffTableRow], store: DiffReviewStore) {
        for comment in store.comments(for: target) {
            rows.append(.fileComment(file, comment))
        }
        if store.activeCommentTarget == target {
            rows.append(.fileCommentEditor(file))
        }
    }

    @MainActor
    private static func appendLineCommentRows(fileID: String, line: DiffLine, rows: inout [DiffTableRow], store: DiffReviewStore) {
        guard line.kind != .metadata else { return }
        let target = DiffCommentTarget.line(fileID: fileID, line: line)
        for comment in store.comments(for: target) {
            rows.append(.lineComment(fileID: fileID, target: target, comment: comment))
        }
        if store.activeCommentTarget == target {
            rows.append(.lineCommentEditor(fileID: fileID, target: target))
        }
    }
}

private enum DiffTableLayout {
    static let outerLeading: CGFloat = 16
    static let outerTrailing: CGFloat = 18
    static let comment: CGFloat = 22
    static let lineNumber: CGFloat = 32
    static let codeLeadingGap: CGFloat = 8
    static let unifiedGutter = comment + lineNumber + lineNumber + codeLeadingGap
    static let splitGutter = comment + lineNumber + codeLeadingGap
}

private final class FileHeaderCellView: NSTableCellView {
    init(
        file: DiffFile,
        isSelected: Bool,
        isCollapsed: Bool,
        isViewed: Bool,
        commentCount: Int,
        repoRoot: String,
        onSelect: @escaping () -> Void,
        onToggleCollapse: @escaping () -> Void,
        onToggleViewed: @escaping () -> Void,
        onComment: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSPrimer.canvasDefault.cgColor

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = NSPrimer.canvasSubtle.cgColor
        card.layer?.borderColor = (isSelected ? NSPrimer.accentEmphasis : NSPrimer.borderDefault).cgColor
        card.layer?.borderWidth = isSelected ? 2 : 1
        addSubview(card)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let pathButton = ClosureButton(title: file.displayPath) {
            onSelect()
            onToggleCollapse()
        }
        pathButton.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        pathButton.imagePosition = .imageLeft
        pathButton.isBordered = false
        pathButton.contentTintColor = NSPrimer.fgMuted
        pathButton.attributedTitle = NSAttributedString(
            string: file.displayPath,
            attributes: [.foregroundColor: NSPrimer.fgDefault, .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)]
        )
        pathButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathButton.toolTip = isCollapsed ? "Expand file" : "Collapse file"
        stack.addArrangedSubview(pathButton)

        stack.addArrangedSubview(iconButton(systemName: "doc.on.doc", tooltip: "Copy path") {
            copyToPasteboard(file.newPath ?? file.oldPath ?? file.displayPath)
        })
        stack.addArrangedSubview(iconButton(systemName: "arrow.up.forward.square", tooltip: "Open file") {
            openFile(file, repoRoot: repoRoot)
        })

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        stack.addArrangedSubview(DiffStatAppKitView(insertions: file.insertions, deletions: file.deletions))

        let viewedButton = ClosureButton(title: "Viewed") { onToggleViewed() }
        viewedButton.image = NSImage(systemSymbolName: isViewed ? "checkmark.square.fill" : "square", accessibilityDescription: nil)
        viewedButton.imagePosition = .imageLeft
        viewedButton.bezelStyle = .rounded
        viewedButton.font = .systemFont(ofSize: 13, weight: .semibold)
        viewedButton.contentTintColor = NSPrimer.fgDefault
        viewedButton.toolTip = "Mark as viewed"
        stack.addArrangedSubview(viewedButton)

        let commentButton = iconButton(systemName: "bubble", tooltip: commentCount > 0 ? "Add file comment (\(commentCount))" : "Add file comment") {
            onComment()
        }
        stack.addArrangedSubview(commentButton)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffTableLayout.outerLeading),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DiffTableLayout.outerTrailing),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            stack.heightAnchor.constraint(lessThanOrEqualTo: card.heightAnchor, constant: -4),
            pathButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MetadataDiffCellView: NSTableCellView {
    init(text: String, mode: DiffViewMode) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSPrimer.canvasDefault.cgColor
        let label = textLabel(text, color: NSPrimer.fgSubtle, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffTableLayout.outerLeading + (mode == .unified ? DiffTableLayout.unifiedGutter : DiffTableLayout.splitGutter)),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DiffTableLayout.outerTrailing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class HunkDiffCellView: NSTableCellView {
    init(hunk: DiffHunk, mode: DiffViewMode) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSPrimer.accentMuted.cgColor
        let label = textLabel(hunk.header, color: NSPrimer.accentFg, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold))
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffTableLayout.outerLeading + (mode == .unified ? DiffTableLayout.unifiedGutter : DiffTableLayout.splitGutter)),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DiffTableLayout.outerTrailing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class UnifiedLineCellView: HoverDiffCellView {
    init(
        file: DiffFile,
        line: DiffLine,
        wrapLines: Bool,
        commentsCount: Int,
        highlighter: AppKitSyntaxHighlighter,
        onSelectFile: @escaping () -> Void,
        onComment: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        configureHoverButton(hasComments: commentsCount > 0, onComment: onComment)
        wantsLayer = true
        layer?.backgroundColor = NSDiffColors.rowBackground(line.kind).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(commentColumn)
        stack.addArrangedSubview(lineNumberView(line.oldNumber, active: line.kind == .deletion, kind: line.kind))
        stack.addArrangedSubview(lineNumberView(line.newNumber, active: line.kind == .addition, kind: line.kind))
        stack.addArrangedSubview(fixedWidthSpacer(DiffTableLayout.codeLeadingGap))
        let code = codeTextField(
            attributed: highlighter.highlight(text: line.text.isEmpty ? " " : line.text, filePath: filePath(file), baseColor: NSDiffColors.rowTextColor(line.kind)),
            wrapLines: wrapLines
        )
        stack.addArrangedSubview(code)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffTableLayout.outerLeading),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DiffTableLayout.outerTrailing),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            commentColumn.widthAnchor.constraint(equalToConstant: DiffTableLayout.comment)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class SplitLineCellView: HoverDiffCellView {
    init(
        file: DiffFile,
        row: SplitDiffRow,
        wrapLines: Bool,
        commentsCount: Int,
        highlighter: AppKitSyntaxHighlighter,
        onSelectFile: @escaping () -> Void,
        onComment: @escaping (DiffCommentTarget) -> Void
    ) {
        super.init(frame: .zero)
        configureHoverButton(hasComments: commentsCount > 0) {
            if let line = row.oldLine, line.kind != .metadata {
                onComment(.line(fileID: file.id, line: line))
            } else if let line = row.newLine, line.kind != .metadata {
                onComment(.line(fileID: file.id, line: line))
            }
        }
        wantsLayer = true
        layer?.backgroundColor = NSPrimer.canvasDefault.cgColor

        let leftCell = splitCell(file: file, line: row.oldLine, side: .original, wrapLines: wrapLines, highlighter: highlighter)
        let rightCell = splitCell(file: file, line: row.newLine, side: .modified, wrapLines: wrapLines, highlighter: highlighter)
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSPrimer.borderMuted.cgColor

        addSubview(leftCell)
        addSubview(divider)
        addSubview(rightCell)

        NSLayoutConstraint.activate([
            leftCell.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffTableLayout.outerLeading),
            leftCell.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            leftCell.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            divider.leadingAnchor.constraint(equalTo: leftCell.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            divider.widthAnchor.constraint(equalToConstant: 1),

            rightCell.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightCell.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DiffTableLayout.outerTrailing),
            rightCell.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            rightCell.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            rightCell.widthAnchor.constraint(equalTo: leftCell.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func splitCell(file: DiffFile, line: DiffLine?, side: DiffCommentTarget.Side, wrapLines: Bool, highlighter: AppKitSyntaxHighlighter) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = line.map { NSDiffColors.rowBackground($0.kind).cgColor } ?? NSPrimer.canvasDefault.cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let blankComment = NSView()
        blankComment.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(blankComment)
        let active = line.map { $0.kind == .addition || $0.kind == .deletion } ?? false
        let number: Int? = {
            guard let line else { return nil }
            switch side {
            case .original: return line.oldNumber
            case .modified, .file: return line.newNumber
            }
        }()
        stack.addArrangedSubview(lineNumberView(number, active: active, kind: line?.kind ?? .context))
        stack.addArrangedSubview(fixedWidthSpacer(DiffTableLayout.codeLeadingGap))
        let text = line?.text.isEmpty == false ? line!.text : " "
        let color = line.map { NSDiffColors.rowTextColor($0.kind) } ?? NSPrimer.fgSubtle
        stack.addArrangedSubview(codeTextField(
            attributed: highlighter.highlight(text: text, filePath: filePath(file), baseColor: color),
            wrapLines: wrapLines
        ))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blankComment.widthAnchor.constraint(equalToConstant: DiffTableLayout.comment),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        return container
    }
}

private final class LargeDiffFooterCellView: NSTableCellView {
    init(totalRows: Int, visibleRows: Int, isExpanded: Bool, onToggle: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSPrimer.canvasSubtle.cgColor
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let icon = textLabel("⚡", color: NSPrimer.attentionFg, font: .systemFont(ofSize: 13, weight: .semibold))
        stack.addArrangedSubview(icon)
        let message = isExpanded ? "Showing all \(totalRows) diff rows." : "Showing \(visibleRows) of \(totalRows) diff rows for performance."
        let label = textLabel(message, color: NSPrimer.fgMuted, font: .systemFont(ofSize: 12.5, weight: .medium))
        stack.addArrangedSubview(label)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        let button = ClosureButton(title: isExpanded ? "Collapse preview" : "Show full diff") { onToggle() }
        button.bezelStyle = .rounded
        stack.addArrangedSubview(button)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffTableLayout.outerLeading + 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DiffTableLayout.outerTrailing - 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class SavedCommentCellView: NSTableCellView {
    init(comment: DiffReviewComment) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSPrimer.canvasDefault.cgColor
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSPrimer.canvasSubtle.cgColor
        box.layer?.borderColor = NSPrimer.borderDefault.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 6
        addSubview(box)
        let label = textLabel(comment.body, color: NSPrimer.fgDefault, font: .systemFont(ofSize: 12.5, weight: .regular))
        label.maximumNumberOfLines = 2
        box.addSubview(label)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffTableLayout.outerLeading + DiffTableLayout.unifiedGutter),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DiffTableLayout.outerTrailing - 14),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class CommentEditorCellView: NSTableCellView {
    private let textView = NSTextView()

    init(draft: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSPrimer.canvasDefault.cgColor

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSPrimer.canvasSubtle.cgColor
        box.layer?.borderColor = NSPrimer.accentEmphasis.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 6
        addSubview(box)

        textView.string = draft
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = NSPrimer.fgDefault
        textView.backgroundColor = NSPrimer.canvasInset
        textView.insertionPointColor = NSPrimer.fgDefault
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let textScroll = NSScrollView()
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.borderType = .bezelBorder
        textScroll.hasVerticalScroller = true
        textScroll.documentView = textView
        box.addSubview(textScroll)

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(buttonStack)
        let save = ClosureButton(title: "Add comment") { [weak textView] in onSave(textView?.string ?? "") }
        save.bezelStyle = .rounded
        let cancel = ClosureButton(title: "Cancel") { onCancel() }
        cancel.bezelStyle = .rounded
        buttonStack.addArrangedSubview(save)
        buttonStack.addArrangedSubview(cancel)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffTableLayout.outerLeading + DiffTableLayout.unifiedGutter),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DiffTableLayout.outerTrailing - 14),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            textScroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            textScroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            textScroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            textScroll.heightAnchor.constraint(equalToConstant: 72),
            buttonStack.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor),
            buttonStack.topAnchor.constraint(equalTo: textScroll.bottomAnchor, constant: 8),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder !== self.textView else { return }
            self.window?.makeFirstResponder(self.textView)
        }
    }
}

private final class EmptyDiffCellView: NSTableCellView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSPrimer.canvasDefault.cgColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let icon = textLabel("▱", color: NSPrimer.fgSubtle, font: .systemFont(ofSize: 28, weight: .light))
        let label = textLabel("No files match your filter", color: NSPrimer.fgSubtle, font: .systemFont(ofSize: 14, weight: .medium))
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private class HoverDiffCellView: NSTableCellView {
    private weak static var activeHoverCell: HoverDiffCellView?

    let commentColumn = NSView()
    private var hoverTrackingArea: NSTrackingArea?
    private var commentButton: ClosureButton?
    private var persistent = false

    func configureHoverButton(hasComments: Bool, onComment: @escaping () -> Void) {
        persistent = hasComments
        commentColumn.translatesAutoresizingMaskIntoConstraints = false
        let button = ClosureButton(title: "+") { onComment() }
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .bold)
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSPrimer.accentEmphasis.cgColor
        button.layer?.cornerRadius = 4
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = !hasComments
        commentColumn.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: commentColumn.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: commentColumn.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 14),
            button.heightAnchor.constraint(equalToConstant: 14)
        ])
        commentButton = button
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard NSApp.currentEvent?.type != .leftMouseDragged else {
            hideHoverButton()
            return
        }
        showHoverButton()
    }

    override func mouseExited(with event: NSEvent) {
        hideHoverButton()
    }

    override func mouseDown(with event: NSEvent) {
        hideHoverButton()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        hideHoverButton()
        super.mouseDragged(with: event)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if Self.activeHoverCell === self {
            Self.activeHoverCell = nil
        }
        hideHoverButton()
    }

    private func showHoverButton() {
        if Self.activeHoverCell !== self {
            Self.activeHoverCell?.hideHoverButton()
            Self.activeHoverCell = self
        }
        commentButton?.isHidden = false
    }

    private func hideHoverButton() {
        if Self.activeHoverCell === self {
            Self.activeHoverCell = nil
        }
        commentButton?.isHidden = !persistent
    }
}

private final class DiffStatAppKitView: NSView {
    init(insertions: Int, deletions: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        if insertions > 0 {
            stack.addArrangedSubview(textLabel("+\(formattedCount(insertions))", color: NSPrimer.successFg, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)))
        }
        if deletions > 0 {
            stack.addArrangedSubview(textLabel("-\(formattedCount(deletions))", color: NSPrimer.dangerFg, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)))
        }

        let blocks = NSStackView()
        blocks.orientation = .horizontal
        blocks.spacing = 2
        let segments = Self.segments(insertions: insertions, deletions: deletions)
        for index in 0..<5 {
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.wantsLayer = true
            view.layer?.cornerRadius = 2
            if index < segments.insertions {
                view.layer?.backgroundColor = NSPrimer.successFg.withAlphaComponent(0.85).cgColor
            } else if index < segments.insertions + segments.deletions {
                view.layer?.backgroundColor = NSPrimer.dangerFg.withAlphaComponent(0.85).cgColor
            } else {
                view.layer?.backgroundColor = NSPrimer.neutralMuted.cgColor
            }
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 8),
                view.heightAnchor.constraint(equalToConstant: 8)
            ])
            blocks.addArrangedSubview(view)
        }
        stack.addArrangedSubview(blocks)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func segments(insertions: Int, deletions: Int) -> (insertions: Int, deletions: Int) {
        let total = insertions + deletions
        guard total > 0 else { return (0, 0) }
        var green = insertions > 0 ? max(1, Int((Double(insertions) / Double(total) * 5.0).rounded())) : 0
        var red = deletions > 0 ? max(1, 5 - green) : 0
        if insertions == 0 { red = min(5, red) }
        if deletions == 0 { green = min(5, green) }
        if green + red > 5 {
            if green > red { green = 5 - red } else { red = 5 - green }
        }
        return (green, red)
    }
}

private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(invoke)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func invoke() {
        handler()
    }
}

private func iconButton(systemName: String, tooltip: String, handler: @escaping () -> Void) -> ClosureButton {
    let button = ClosureButton(title: "", handler: handler)
    button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
    button.isBordered = false
    button.contentTintColor = NSPrimer.fgMuted
    button.toolTip = tooltip
    NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 26),
        button.heightAnchor.constraint(equalToConstant: 28)
    ])
    return button
}

private func textLabel(_ text: String, color: NSColor, font: NSFont) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.textColor = color
    label.font = font
    label.isSelectable = true
    label.lineBreakMode = .byTruncatingMiddle
    return label
}

private func fixedWidthSpacer(_ width: CGFloat) -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: width).isActive = true
    return view
}

private func codeTextField(attributed: NSAttributedString, wrapLines: Bool) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.translatesAutoresizingMaskIntoConstraints = false
    field.attributedStringValue = attributed
    field.isSelectable = true
    field.maximumNumberOfLines = wrapLines ? 0 : 1
    field.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

private func lineNumberView(_ number: Int?, active: Bool, kind: DiffLineKind) -> NSView {
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.wantsLayer = true
    container.layer?.backgroundColor = active ? NSDiffColors.activeLineNumberBackground(kind).cgColor : NSColor.clear.cgColor
    let label = textLabel(number.map(String.init) ?? "", color: active ? NSPrimer.fgDefault : NSPrimer.fgSubtle, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    label.alignment = .right
    container.addSubview(label)
    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: DiffTableLayout.lineNumber),
        label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
        label.topAnchor.constraint(equalTo: container.topAnchor),
        label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
    ])
    return container
}

private func filePath(_ file: DiffFile) -> String {
    file.newPath ?? file.oldPath ?? file.displayPath
}

private enum NSDiffColors {
    static func rowBackground(_ kind: DiffLineKind) -> NSColor {
        switch kind {
        case .addition: return NSPrimer.successSubtle
        case .deletion: return NSPrimer.dangerSubtle
        case .metadata: return NSPrimer.canvasSubtle
        case .context: return NSPrimer.canvasDefault
        }
    }

    static func rowTextColor(_ kind: DiffLineKind) -> NSColor {
        switch kind {
        case .addition: return NSPrimer.successText
        case .deletion: return NSPrimer.dangerText
        case .metadata: return NSPrimer.fgSubtle
        case .context: return NSPrimer.fgDefault
        }
    }

    static func activeLineNumberBackground(_ kind: DiffLineKind) -> NSColor {
        switch kind {
        case .addition: return NSPrimer.successMuted
        case .deletion: return NSPrimer.dangerMuted
        default: return .clear
        }
    }
}

private final class AppKitSyntaxHighlighter {
    private let cache = NSCache<NSString, NSAttributedString>()
    private let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    func highlight(text: String, filePath: String, baseColor: NSColor) -> NSAttributedString {
        let key = "\(filePath)|\(baseColor.hexKey)|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: baseColor,
            .font: font
        ])

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
            attributed.addAttribute(.foregroundColor, value: NSPrimer.fgSubtle, range: NSRange(location: 0, length: (text as NSString).length))
            cache.setObject(attributed, forKey: key)
            return attributed
        }

        let keywords = keywordSet(filePath: filePath)
        if keywords.isEmpty {
            cache.setObject(attributed, forKey: key)
            return attributed
        }

        let nsText = text as NSString
        let pattern = #"\b([A-Za-z_][A-Za-z0-9_]*)\b|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            cache.setObject(attributed, forKey: key)
            return attributed
        }

        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let token = nsText.substring(with: match.range)
            if token.hasPrefix("\"") || token.hasPrefix("'") {
                attributed.addAttribute(.foregroundColor, value: NSPrimer.doneFg, range: match.range)
            } else if keywords.contains(token) {
                attributed.addAttribute(.foregroundColor, value: NSPrimer.prettylightsSyntaxKeyword, range: match.range)
            }
        }

        cache.setObject(attributed, forKey: key)
        return attributed
    }

    private func keywordSet(filePath: String) -> Set<String> {
        let lower = filePath.lowercased()
        if lower.hasSuffix(".swift") {
            return ["import", "struct", "class", "enum", "func", "let", "var", "private", "public", "return", "if", "else", "switch", "case", "guard", "for", "while", "in", "extension", "protocol", "some", "View", "final", "static"]
        }
        if lower.hasSuffix(".ts") || lower.hasSuffix(".tsx") || lower.hasSuffix(".js") || lower.hasSuffix(".jsx") {
            return ["import", "from", "export", "const", "let", "var", "function", "return", "if", "else", "switch", "case", "interface", "type", "class", "extends", "async", "await", "private", "public"]
        }
        return []
    }
}

private enum NSPrimer {
    static let canvasDefault = NSColor(hex: "#0d1117")
    static let canvasSubtle = NSColor(hex: "#161b22")
    static let canvasInset = NSColor(hex: "#010409")
    static let borderDefault = NSColor(hex: "#30363d")
    static let borderMuted = NSColor(hex: "#21262d")
    static let fgDefault = NSColor(hex: "#e6edf3")
    static let fgMuted = NSColor(hex: "#8b949e")
    static let fgSubtle = NSColor(hex: "#6e7681")
    static let accentFg = NSColor(hex: "#58a6ff")
    static let accentEmphasis = NSColor(hex: "#1f6feb")
    static let accentMuted = NSColor(hex: "#1f6feb").withAlphaComponent(0.18)
    static let successFg = NSColor(hex: "#3fb950")
    static let successText = NSColor(hex: "#d1f8d7")
    static let successSubtle = NSColor(hex: "#0f2f1d")
    static let successMuted = NSColor(hex: "#238636").withAlphaComponent(0.45)
    static let dangerFg = NSColor(hex: "#f85149")
    static let dangerText = NSColor(hex: "#ffdcd7")
    static let dangerSubtle = NSColor(hex: "#3b1518")
    static let dangerMuted = NSColor(hex: "#da3633").withAlphaComponent(0.45)
    static let attentionFg = NSColor(hex: "#d29922")
    static let doneFg = NSColor(hex: "#a5d6ff")
    static let neutralMuted = NSColor(hex: "#6e7681").withAlphaComponent(0.28)
    static let prettylightsSyntaxKeyword = NSColor(hex: "#ff7b72")
}

private extension NSColor {
    convenience init(hex: String) {
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
        self.init(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var hexKey: String {
        guard let rgb = usingColorSpace(.sRGB) else { return description }
        return String(format: "%.3f:%.3f:%.3f:%.3f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }
}
