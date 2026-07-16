//
//  PickyBubbleMarkdownContentView.swift
//  Picky
//
//  AppKit-owned markdown content used inside conversation bubble surfaces.
//  The parent bubble may receive a full-width SwiftUI/AppKit host frame; this
//  view keeps markdown measurement and special block rendering inside the
//  same AppKit boundary as the visible bubble rect.
//

import AppKit
import SwiftUI

final class PickyBubbleMarkdownContentView: NSView {
    private enum Metrics {
        static let blockSpacing: CGFloat = 5
        static let blockPadding: CGFloat = 8
        static let codeCornerRadius: CGFloat = 7
        static let slowMeasureLogThreshold: TimeInterval = 0.05
    }

    private enum RenderBlock: Equatable {
        case inline([PickyMarkdownInlineTextView.InlineBlock])
        case table(headers: [String], rows: [[String]])
        case codeBlock(String)
    }

    private let renderer = PickyReportMarkdownRenderer()
    private let linkDelegate = PickyMarkdownLinkTextViewDelegate()
    private var blockViews: [PickyMarkdownBlockNSView] = []
    private var cachedBlocks: [RenderBlock] = []
    /// Last per-code-block line cap used to build block views. `0` means no
    /// code-block truncation, used for the newest LLM response bubble.
    private var cachedCodeBlockMaxLines = PickyAgentResponsePreview.codeBlockMaxLines
    /// Last global app font scale this view rendered with. When the user hits
    /// ⌘+ / ⌘-, `PickyAppFontScaleStore.staticScale` changes and the cached
    /// `RenderBlock` array would otherwise short-circuit the rebuild because
    /// the markdown text itself didn't change. Tracking the build scale here
    /// forces a rebuild on the next `configure(...)` call so the block subviews
    /// (and their NSAttributedString font attributes) come up at the new size.
    private var cachedFontScale: CGFloat = 0
    /// Last markdown string this view configured with. Used to short-circuit
    /// `renderBlocks(...)` + the block-diff scan + `needsLayout` /
    /// `invalidateIntrinsicContentSize` when the parent re-invokes
    /// `configure(...)` with an unchanged markdown payload (e.g., during
    /// streaming when an unrelated session republish triggers SwiftUI to
    /// re-evaluate the bubble surface). Optional so the first call always
    /// performs a real render — markdown is arbitrary input so we cannot
    /// pick a sentinel value safely.
    private var lastMarkdown: String?

    var onOpenAsReport: (() -> Void)? {
        didSet { blockViews.forEach { $0.onOpenAsReport = onOpenAsReport } }
    }
    var onCopyText: (() -> Void)? {
        didSet { blockViews.forEach { $0.onCopyText = onCopyText } }
    }
    var onEditText: (() -> Void)? {
        didSet { blockViews.forEach { $0.onEditText = onEditText } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(
        markdown: String,
        codeBlockMaxLines: Int = PickyAgentResponsePreview.codeBlockMaxLines,
        onOpenAsReport: (() -> Void)?,
        onCopyText: (() -> Void)?,
        onEditText: (() -> Void)?
    ) {
        PickyPerf.interval("bubble_configure") {
        let currentScale = PickyAppFontScaleStore.staticCGScale
        let markdownDidChange = markdown != lastMarkdown
        let scaleDidChange = currentScale != cachedFontScale
        let codeBlockLimitDidChange = codeBlockMaxLines != cachedCodeBlockMaxLines

        // Short-circuit when the markdown payload, global font scale, and
        // code-block preview policy are unchanged from the last configure call.
        // Callback setters still run below so hover/copy actions stay current.
        // Skipping `renderBlocks` + `needsLayout` +
        // `invalidateIntrinsicContentSize` is the streaming hot-path win: an
        // unrelated session republish that re-invokes SwiftUI's `updateNSView`
        // for this bubble now costs only three property assignments instead of
        // a full cmark parse.
        if markdownDidChange || scaleDidChange || codeBlockLimitDidChange {
            let blocks = PickyPerf.interval("render_blocks") { renderBlocks(from: markdown) }
            if blocks != cachedBlocks || scaleDidChange || codeBlockLimitDidChange {
                PickyPerf.interval("rebuild_block_views") {
                    blockViews.forEach { $0.removeFromSuperview() }
                    blockViews = blocks.map { makeBlockView(for: $0, codeBlockMaxLines: codeBlockMaxLines) }
                    blockViews.forEach { addSubview($0) }
                    cachedBlocks = blocks
                }
                // Block-view set just changed; stale (width, size) pairs no
                // longer match the new content. The font-scale-only branch
                // also lands here (inner `if` guard) so a ⌘+/⌘- rebuild
                // flushes the cache too.
                invalidateMeasuredSizeCache()
            }
            // Record the scale even when blocks are unchanged: otherwise
            // every subsequent configure call with the same markdown would
            // re-enter this branch and re-parse markdown until the next
            // mutation, defeating the short-circuit.
            cachedFontScale = currentScale
            cachedCodeBlockMaxLines = codeBlockMaxLines
            lastMarkdown = markdown
            needsLayout = true
            invalidateIntrinsicContentSize()
        }

        self.onOpenAsReport = onOpenAsReport
        self.onCopyText = onCopyText
        self.onEditText = onEditText
        }
    }

    /// Width-keyed cache. AppKit's layout cycle invokes `measuredSize(forWidth:)`
    /// many times during a single pass, but — critically — `PickyAgentBubbleSurfaceNSView`
    /// measures at TWO alternating widths per pass: the bubble cap
    /// (`measuredBubbleWidth`) and the narrower content-fit width
    /// (`measuredBubbleHeight`/`layout`). A single-slot `(width, size)` cache
    /// thrashes between those two values and misses on essentially every call,
    /// which profiling caught dominating HUD time again (~93% of hud-perf,
    /// single measures up to ~1.1s while expanding large bubbles). Keep a small
    /// per-width map instead so both widths stay resident across the pass.
    /// Bounded because a bubble realistically only sees a handful of widths
    /// (cap + content-fit, plus transient widths during a panel drag).
    private var measuredSizeCache: [CGFloat: NSSize] = [:]
    private static let measuredSizeCacheLimit = 8

    func measuredSize(forWidth width: CGFloat) -> NSSize {
        if let cached = measuredSizeCache[width] {
            return cached
        }
        let startedAt = Date()
        let measured: NSSize = PickyPerf.interval("bubble_measured_size") {
            let clamped = max(0, width)
            guard clamped > 0, !blockViews.isEmpty else { return .zero }

            var measuredWidth: CGFloat = 0
            var measuredHeight: CGFloat = 0
            for (index, blockView) in blockViews.enumerated() {
                let size = blockView.measuredSize(forWidth: clamped)
                measuredWidth = max(measuredWidth, size.width)
                measuredHeight += ceil(size.height)
                if index < blockViews.count - 1 {
                    measuredHeight += Metrics.blockSpacing
                }
            }
            return NSSize(width: min(clamped, ceil(measuredWidth)), height: ceil(measuredHeight))
        }
        logSlowMeasurementIfNeeded(
            name: "bubble measured size slow",
            duration: Date().timeIntervalSince(startedAt),
            details: "width=\(Int(max(0, width).rounded())) blocks=\(blockViews.count) measuredWidth=\(Int(measured.width.rounded())) measuredHeight=\(Int(measured.height.rounded()))"
        )
        if measuredSizeCache.count >= Self.measuredSizeCacheLimit {
            measuredSizeCache.removeAll(keepingCapacity: true)
        }
        measuredSizeCache[width] = measured
        return measured
    }

    /// Invalidate the measured-size cache. Called whenever the underlying
    /// `blockViews` are rebuilt so the next layout pass measures fresh.
    private func invalidateMeasuredSizeCache() {
        measuredSizeCache.removeAll(keepingCapacity: true)
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }

    private func logSlowMeasurementIfNeeded(name: String, duration: TimeInterval, details: String) {
        guard duration >= Metrics.slowMeasureLogThreshold else { return }
        PickyLog.noticeRateLimited(
            .markdown,
            key: "markdown.bubble.\(name)",
            cooldown: 5,
            prefix: "🧾 Picky markdown —",
            message: "\(name) durationMs=\(Self.milliseconds(duration)) \(details)"
        )
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (index, blockView) in blockViews.enumerated() {
            let size = blockView.measuredSize(forWidth: bounds.width)
            blockView.frame = NSRect(x: 0, y: y, width: min(bounds.width, ceil(size.width)), height: ceil(size.height))
            y += ceil(size.height)
            if index < blockViews.count - 1 {
                y += Metrics.blockSpacing
            }
        }
    }

    private func renderBlocks(from markdown: String) -> [RenderBlock] {
        var groups: [RenderBlock] = []
        var inlineBuffer: [PickyMarkdownInlineTextView.InlineBlock] = []

        func flushInline() {
            guard !inlineBuffer.isEmpty else { return }
            groups.append(.inline(inlineBuffer))
            inlineBuffer.removeAll(keepingCapacity: true)
        }

        for block in renderer.blocks(from: markdown) {
            switch block {
            case .heading(let level, let text):
                inlineBuffer.append(.heading(level: level, text: text))
            case .paragraph(let text):
                inlineBuffer.append(.paragraph(text))
            case .bullet(let text):
                inlineBuffer.append(.bullet(text))
            case .table(let headers, let rows):
                flushInline()
                groups.append(.table(headers: headers, rows: rows))
            case .codeBlock(let text):
                flushInline()
                groups.append(.codeBlock(text))
            }
        }
        flushInline()
        return groups.isEmpty ? [.inline([.paragraph("")])] : groups
    }

    private func makeBlockView(for block: RenderBlock, codeBlockMaxLines: Int) -> PickyMarkdownBlockNSView {
        let view: PickyMarkdownBlockNSView
        switch block {
        case .inline(let blocks):
            view = PickyInlineMarkdownBlockView(blocks: blocks, linkDelegate: linkDelegate)
        case .table(let headers, let rows):
            view = PickyTableMarkdownBlockView(headers: headers, rows: rows)
        case .codeBlock(let text):
            view = PickyCodeMarkdownBlockView(text: text, maxLines: codeBlockMaxLines)
        }
        view.onOpenAsReport = onOpenAsReport
        view.onCopyText = onCopyText
        view.onEditText = onEditText
        return view
    }
}

final class PickyMarkdownLinkTextViewDelegate: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let resolved: URL?
        if let url = link as? URL {
            resolved = url
        } else if let string = link as? String {
            resolved = URL(string: string)
        } else {
            resolved = nil
        }
        guard let url = resolved else { return false }
        return PickyDeepLinkDispatcher.shared.handle(url)
    }
}

class PickyMarkdownBlockNSView: NSView {
    var onOpenAsReport: (() -> Void)?
    var onCopyText: (() -> Void)?
    var onEditText: (() -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Width-keyed (width → size) cache. Every concrete subclass holds
    /// immutable rendered content (NSAttributedString set once in init), so
    /// measurement is deterministic for a given width across the view's
    /// lifetime — a per-width map can never go stale and needs no
    /// invalidation. The parent surface measures at two alternating widths
    /// (cap + content-fit) per layout pass, so a single-slot cache would
    /// thrash and miss on every call; the map keeps both resident.
    private var measuredSizeCache: [CGFloat: NSSize] = [:]
    private static let measuredSizeCacheLimit = 8

    final func measuredSize(forWidth width: CGFloat) -> NSSize {
        if let cached = measuredSizeCache[width] {
            return cached
        }
        let size = computeMeasuredSize(forWidth: width)
        if measuredSizeCache.count >= Self.measuredSizeCacheLimit {
            measuredSizeCache.removeAll(keepingCapacity: true)
        }
        measuredSizeCache[width] = size
        return size
    }

    /// Subclasses override this to perform the actual measurement. The base
    /// class wraps the call in the cache; do not call this directly from
    /// outside the subclass override — use `measuredSize(forWidth:)`.
    func computeMeasuredSize(forWidth width: CGFloat) -> NSSize { .zero }
}

private final class PickyInlineMarkdownBlockView: PickyMarkdownBlockNSView {
    private let textView = SelfSizingMarkdownTextView()

    init(blocks: [PickyMarkdownInlineTextView.InlineBlock], linkDelegate: NSTextViewDelegate) {
        super.init(frame: .zero)
        textView.delegate = linkDelegate
        textView.fillsAvailableWidth = false
        textView.textContainerInset = .zero
        textView.drawsBackground = false
        textView.textStorage?.setAttributedString(PickyMarkdownInlineTextView.buildAttributedString(from: blocks))
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var onOpenAsReport: (() -> Void)? {
        didSet { textView.onOpenAsReport = onOpenAsReport }
    }
    override var onCopyText: (() -> Void)? {
        didSet { textView.onCopyText = onCopyText }
    }
    override var onEditText: (() -> Void)? {
        didSet { textView.onEditText = onEditText }
    }

    override func computeMeasuredSize(forWidth width: CGFloat) -> NSSize {
        let width = max(0, width)
        let attributed = textView.attributedString()
        guard width > 0, attributed.length > 0 else { return .zero }
        textView.hugContentMaxWidth = width
        let rect = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: min(width, ceil(rect.width)), height: ceil(rect.height))
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
    }
}

private final class PickyCodeMarkdownBlockView: PickyMarkdownBlockNSView {
    private enum Metrics {
        static let padding: CGFloat = 8
        static let cornerRadius: CGFloat = 7
        static let separatorHeight: CGFloat = 0.5
        static let omittedHeight: CGFloat = 20
    }

    private let textView = SelfSizingMarkdownTextView()
    private let scrollView = NSScrollView()
    private let omittedField = NSTextField(labelWithString: "")
    private let displayText: String
    private let omittedCount: Int

    init(text: String, maxLines: Int = PickyAgentResponsePreview.codeBlockMaxLines) {
        let lines = text.components(separatedBy: "\n")
        let isTruncated = maxLines > 0 && lines.count > maxLines
        displayText = isTruncated ? lines.prefix(maxLines).joined(separator: "\n") : text
        omittedCount = isTruncated ? lines.count - maxLines : 0
        super.init(frame: .zero)

        textView.fillsAvailableWidth = false
        textView.textContainerInset = .zero
        textView.drawsBackground = false
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: displayText.isEmpty ? " " : displayText,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: PickyHUDTypography.Size.supporting, weight: .regular),
                .foregroundColor: NSColor(DS.Colors.codeText)
            ]
        ))

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        addSubview(scrollView)

        omittedField.font = NSFont.systemFont(ofSize: PickyHUDTypography.Size.meta, weight: .medium)
        omittedField.textColor = NSColor(DS.Colors.textTertiary)
        omittedField.backgroundColor = .clear
        omittedField.isBordered = false
        omittedField.isEditable = false
        omittedField.isSelectable = false
        omittedField.stringValue = omittedCount > 0 ? "… +\(omittedCount) more line\(omittedCount == 1 ? "" : "s")" : ""
        omittedField.isHidden = omittedCount == 0
        addSubview(omittedField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var onOpenAsReport: (() -> Void)? {
        didSet { textView.onOpenAsReport = onOpenAsReport }
    }
    override var onCopyText: (() -> Void)? {
        didSet { textView.onCopyText = onCopyText }
    }
    override var onEditText: (() -> Void)? {
        didSet { textView.onEditText = onEditText }
    }

    override func computeMeasuredSize(forWidth width: CGFloat) -> NSSize {
        let cap = max(0, width)
        guard cap > 0 else { return .zero }
        let textSize = textView.measureUnwrappedSize()
        let omittedHeight = omittedCount > 0 ? Metrics.omittedHeight : 0
        let measuredWidth = min(cap, ceil(textSize.width) + 2 * Metrics.padding)
        let measuredHeight = Metrics.padding + ceil(textSize.height) + Metrics.padding + omittedHeight
        return NSSize(width: measuredWidth, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let textCap = max(0, bounds.width - 2 * Metrics.padding)
        let textSize = textView.measureUnwrappedSize()
        let textHeight = ceil(textSize.height)
        scrollView.frame = NSRect(
            x: Metrics.padding,
            y: Metrics.padding,
            width: textCap,
            height: textHeight
        )
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(textCap, ceil(textSize.width)),
            height: textHeight
        )
        if omittedCount > 0 {
            omittedField.frame = NSRect(
                x: Metrics.padding,
                y: bounds.height - Metrics.omittedHeight,
                width: max(0, bounds.width - 2 * Metrics.padding),
                height: Metrics.omittedHeight
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius)
        NSColor(DS.Colors.surface2).setFill()
        path.fill()
        NSColor(DS.Colors.borderSubtle).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        if omittedCount > 0 {
            NSColor(DS.Colors.borderSubtle.opacity(0.6)).setFill()
            NSRect(x: 0, y: bounds.height - Metrics.omittedHeight, width: bounds.width, height: Metrics.separatorHeight).fill()
            NSColor(DS.Colors.surface3.opacity(0.55)).setFill()
            NSRect(x: 0, y: bounds.height - Metrics.omittedHeight + Metrics.separatorHeight, width: bounds.width, height: Metrics.omittedHeight - Metrics.separatorHeight).fill()
        }
    }
}

private final class PickyTableMarkdownBlockView: PickyMarkdownBlockNSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 7
        static let slowTableLayoutLogThreshold: TimeInterval = 0.05
    }

    private let scrollView = NSScrollView()
    private let gridView: GridDocumentView
    /// Content-derived width per column: the widest single-line cell plus
    /// padding, capped so a very long cell wraps instead of stretching the
    /// whole table.
    private let naturalColumnWidths: [CGFloat]
    /// Uncapped single-line width per column. Used to hand any slack width to
    /// the columns that actually wanted more room rather than padding every
    /// column up to a shared minimum.
    private let desiredColumnWidths: [CGFloat]
    private let dataRowCount: Int
    private let columnCount: Int
    private var layoutCache: [CGFloat: TableLayout] = [:]

    private struct TableLayout {
        let columnWidths: [CGFloat]
        let rowHeights: [CGFloat]
        let size: NSSize
    }

    init(headers: [String], rows: [[String]]) {
        let measured = Self.measureColumns(headers: headers, rows: rows)
        naturalColumnWidths = measured.capped
        desiredColumnWidths = measured.uncapped
        dataRowCount = rows.count
        columnCount = headers.count
        gridView = GridDocumentView(headers: headers, rows: rows, columnWidths: measured.capped)
        super.init(frame: .zero)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = gridView
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func computeMeasuredSize(forWidth width: CGFloat) -> NSSize {
        let cap = max(0, width)
        guard cap > 0 else { return .zero }
        let layout = tableLayout(forWidth: cap)
        return NSSize(width: min(cap, layout.size.width), height: layout.size.height)
    }

    override func layout() {
        super.layout()
        let layout = tableLayout(forWidth: bounds.width)
        scrollView.frame = bounds
        gridView.frame = NSRect(origin: .zero, size: layout.size)
        gridView.apply(columnWidths: layout.columnWidths, rowHeights: layout.rowHeights)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius)
        NSColor(DS.Colors.surface2).setFill()
        path.fill()
        NSColor(DS.Colors.borderSubtle).setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }

    private func tableLayout(forWidth available: CGFloat) -> TableLayout {
        let key = available.rounded()
        if let cached = layoutCache[key] { return cached }
        let startedAt = Date()
        let columnWidths = resolvedColumnWidths(forWidth: available)
        let rowHeights = gridView.measureRowHeights(columnWidths: columnWidths)
        let size = NSSize(
            width: columnWidths.reduce(0, +),
            height: rowHeights.reduce(0, +)
        )
        let layout = TableLayout(columnWidths: columnWidths, rowHeights: rowHeights, size: size)
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Metrics.slowTableLayoutLogThreshold {
            PickyLog.noticeRateLimited(
                .markdown,
                key: "markdown.bubble.table-layout",
                cooldown: 5,
                prefix: "🧾 Picky markdown —",
                message: "bubble table layout slow durationMs=\(Self.milliseconds(elapsed)) columns=\(columnCount) rows=\(dataRowCount) availableWidth=\(Int(available.rounded())) layoutWidth=\(Int(size.width.rounded())) layoutHeight=\(Int(size.height.rounded()))"
            )
        }
        layoutCache[key] = layout
        return layout
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }

    /// Resolve the final column widths for the given available width. Columns
    /// are sized to their content; when the table is narrower than the space
    /// available, the slack goes to the columns whose text was clipped by the
    /// cap, so short columns (an index, a status) stay tight instead of every
    /// column sharing one fixed minimum.
    private func resolvedColumnWidths(forWidth available: CGFloat) -> [CGFloat] {
        let natural = naturalColumnWidths
        let total = natural.reduce(0, +)
        guard available > 0, total > 0, available > total else { return natural }
        let desire = zip(desiredColumnWidths, natural).map { max($0 - $1, 0) }
        let desireTotal = desire.reduce(0, +)
        guard desireTotal > 0 else { return natural }
        let extra = available - total
        return zip(natural, desire).map { $0 + extra * ($1 / desireTotal) }
    }

    private static func measureColumns(
        headers: [String],
        rows: [[String]]
    ) -> (capped: [CGFloat], uncapped: [CGFloat]) {
        let columnCount = headers.count
        guard columnCount > 0 else { return ([], []) }
        let scale = PickyAppFontScaleStore.staticCGScale
        let horizontalPadding = 2 * GridDocumentView.horizontalPadding
        let maxColumnWidth = 360 * scale
        let minColumnWidth = 44 * scale

        var uncapped = [CGFloat](repeating: 0, count: columnCount)
        let allRows = [headers] + rows
        for (rowIndex, cells) in allRows.enumerated() {
            for columnIndex in 0..<columnCount where columnIndex < cells.count {
                let attr = GridDocumentView.attributedCellString(
                    cells[columnIndex],
                    isHeader: rowIndex == 0,
                    columnIndex: columnIndex
                )
                let rect = attr.boundingRect(
                    with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                uncapped[columnIndex] = max(uncapped[columnIndex], ceil(rect.width))
            }
        }
        let uncappedPadded = uncapped.map { $0 + horizontalPadding }
        let capped = uncappedPadded.map { min(max($0, minColumnWidth), maxColumnWidth) }
        return (capped, uncappedPadded)
    }

    private final class GridDocumentView: NSView {
        static let horizontalPadding: CGFloat = 8
        private enum Metrics {
            static let verticalPadding: CGFloat = 6
            static let minRowHeight: CGFloat = 28
            static let separatorWidth: CGFloat = 0.5
        }

        private var columnWidths: [CGFloat]
        private let cellFields: [[NSTextField]]
        private var rowHeights: [CGFloat] = []

        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }

        init(headers: [String], rows: [[String]], columnWidths: [CGFloat]) {
            self.columnWidths = columnWidths
            let tableRows = [headers] + rows
            self.cellFields = tableRows.enumerated().map { rowIndex, cells in
                cells.enumerated().map { columnIndex, cell in
                    Self.makeCellField(
                        text: cell,
                        isHeader: rowIndex == 0,
                        columnIndex: columnIndex
                    )
                }
            }
            super.init(frame: .zero)
            cellFields.flatMap { $0 }.forEach { addSubview($0) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func measureRowHeights(columnWidths: [CGFloat]) -> [CGFloat] {
            cellFields.map { row in
                let maxCellHeight = row.enumerated().map { columnIndex, field in
                    let columnWidth = columnWidths.indices.contains(columnIndex) ? columnWidths[columnIndex] : columnWidths.last ?? 160
                    let textWidth = max(1, columnWidth - 2 * Self.horizontalPadding)
                    let rect = field.attributedStringValue.boundingRect(
                        with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading]
                    )
                    return ceil(rect.height) + 2 * Metrics.verticalPadding
                }.max() ?? 0
                return max(Metrics.minRowHeight, maxCellHeight)
            }
        }

        func apply(columnWidths: [CGFloat], rowHeights: [CGFloat]) {
            self.columnWidths = columnWidths
            self.rowHeights = rowHeights
            needsLayout = true
            needsDisplay = true
        }

        override func layout() {
            super.layout()
            var y: CGFloat = 0
            for rowIndex in cellFields.indices {
                let rowHeight = rowHeights.indices.contains(rowIndex) ? rowHeights[rowIndex] : Metrics.minRowHeight
                var x: CGFloat = 0
                for columnIndex in cellFields[rowIndex].indices {
                    let columnWidth = columnWidths.indices.contains(columnIndex) ? columnWidths[columnIndex] : columnWidths.last ?? 160
                    cellFields[rowIndex][columnIndex].frame = NSRect(
                        x: x + Self.horizontalPadding,
                        y: y + Metrics.verticalPadding,
                        width: max(0, columnWidth - 2 * Self.horizontalPadding),
                        height: max(0, rowHeight - 2 * Metrics.verticalPadding)
                    )
                    x += columnWidth
                }
                y += rowHeight
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            var y: CGFloat = 0
            for rowIndex in cellFields.indices {
                let rowHeight = rowHeights.indices.contains(rowIndex) ? rowHeights[rowIndex] : Metrics.minRowHeight
                let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
                let fillColor = rowIndex == 0 ? NSColor(DS.Colors.surface3.opacity(0.72)) : NSColor(DS.Colors.surface2.opacity(0.38))
                fillColor.setFill()
                rowRect.fill()
                NSColor(DS.Colors.borderSubtle.opacity(0.72)).setFill()
                NSRect(x: 0, y: y + rowHeight - Metrics.separatorWidth, width: bounds.width, height: Metrics.separatorWidth).fill()
                y += rowHeight
            }

            var x: CGFloat = 0
            for width in columnWidths.dropLast() {
                x += width
                NSColor(DS.Colors.borderSubtle.opacity(0.72)).setFill()
                NSRect(x: x - Metrics.separatorWidth, y: 0, width: Metrics.separatorWidth, height: bounds.height).fill()
            }
        }

        private static func makeCellField(text: String, isHeader: Bool, columnIndex: Int) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.attributedStringValue = attributedCellString(text, isHeader: isHeader, columnIndex: columnIndex)
            field.backgroundColor = .clear
            field.isBordered = false
            field.isEditable = false
            field.isSelectable = true
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            return field
        }

        static func attributedCellString(_ text: String, isHeader: Bool, columnIndex: Int) -> NSAttributedString {
            let content = text.isEmpty ? " " : text
            let attr = NSMutableAttributedString(
                attributedString: PickyMarkdownInlineTextView.buildAttributedString(from: [.paragraph(content)])
            )
            let foreground = isHeader ? NSColor(DS.Colors.textPrimary) : NSColor(DS.Colors.textPrimary.opacity(0.92))
            attr.addAttribute(.foregroundColor, value: foreground, range: NSRange(location: 0, length: attr.length))
            if isHeader {
                attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
                    let current = value as? NSFont ?? NSFont.systemFont(ofSize: PickyHUDTypography.Size.body)
                    let replacement = NSFont.systemFont(ofSize: current.pointSize, weight: .semibold)
                    attr.addAttribute(.font, value: replacement, range: range)
                }
            }
            if columnIndex == 0 && !isHeader {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.lineHeightMultiple = 1.1
                attr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attr.length))
            }
            return attr
        }
    }
}
