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
        onOpenAsReport: (() -> Void)?,
        onCopyText: (() -> Void)?,
        onEditText: (() -> Void)?
    ) {
        PickyPerf.interval("bubble_configure") {
        let currentScale = PickyAppFontScaleStore.staticCGScale
        let markdownDidChange = markdown != lastMarkdown
        let scaleDidChange = currentScale != cachedFontScale

        // Short-circuit when both the markdown payload and the global font
        // scale are unchanged from the last configure call. Callback setters
        // still run below so hover/copy actions stay current. Skipping
        // `renderBlocks` + `needsLayout` + `invalidateIntrinsicContentSize`
        // is the streaming hot-path win: an unrelated session republish that
        // re-invokes SwiftUI's `updateNSView` for this bubble now costs only
        // three property assignments instead of a full cmark parse.
        if markdownDidChange || scaleDidChange {
            let blocks = PickyPerf.interval("render_blocks") { renderBlocks(from: markdown) }
            if blocks != cachedBlocks || scaleDidChange {
                PickyPerf.interval("rebuild_block_views") {
                    blockViews.forEach { $0.removeFromSuperview() }
                    blockViews = blocks.map { makeBlockView(for: $0) }
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
            lastMarkdown = markdown
            needsLayout = true
            invalidateIntrinsicContentSize()
        }

        self.onOpenAsReport = onOpenAsReport
        self.onCopyText = onCopyText
        self.onEditText = onEditText
        }
    }

    /// Single-slot cache keyed on the requested width. AppKit's layout cycle
    /// invokes `measuredSize(forWidth:)` many times for the same view at the
    /// same width during a single pass (the bubble surface needs it to size
    /// the rounded rect, then `layout()` needs it again to position the
    /// internal frame). Measurement is deterministic for a fixed block-view
    /// set so we keep the most recent (width, size) pair and short-circuit
    /// repeat queries. Profiling showed this single function dominated HUD
    /// activation time (~83% of hud-perf signpost time) before this cache.
    private var lastMeasuredWidth: CGFloat?
    private var lastMeasuredSize: NSSize = .zero

    func measuredSize(forWidth width: CGFloat) -> NSSize {
        if let cachedWidth = lastMeasuredWidth, cachedWidth == width {
            return lastMeasuredSize
        }
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
        lastMeasuredWidth = width
        lastMeasuredSize = measured
        return measured
    }

    /// Invalidate the measured-size cache. Called whenever the underlying
    /// `blockViews` are rebuilt so the next layout pass measures fresh.
    private func invalidateMeasuredSizeCache() {
        lastMeasuredWidth = nil
        lastMeasuredSize = .zero
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

    private func makeBlockView(for block: RenderBlock) -> PickyMarkdownBlockNSView {
        let view: PickyMarkdownBlockNSView
        switch block {
        case .inline(let blocks):
            view = PickyInlineMarkdownBlockView(blocks: blocks, linkDelegate: linkDelegate)
        case .table(let headers, let rows):
            view = PickyTableMarkdownBlockView(headers: headers, rows: rows)
        case .codeBlock(let text):
            view = PickyCodeMarkdownBlockView(text: text)
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

    /// Single-slot (width, size) cache. Every concrete subclass holds
    /// immutable rendered content (NSAttributedString set once in init), so
    /// measurement is deterministic for a given width across the view's
    /// lifetime. AppKit calls `measuredSize(forWidth:)` repeatedly for the
    /// same view at the same width during a single layout pass; caching
    /// here cuts the bubble-content view's measuredSize cost dramatically.
    private var lastMeasuredWidth: CGFloat?
    private var lastMeasuredSize: NSSize = .zero

    final func measuredSize(forWidth width: CGFloat) -> NSSize {
        if let cachedWidth = lastMeasuredWidth, cachedWidth == width {
            return lastMeasuredSize
        }
        let size = computeMeasuredSize(forWidth: width)
        lastMeasuredWidth = width
        lastMeasuredSize = size
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
    private let omittedField = NSTextField(labelWithString: "")
    private let displayText: String
    private let omittedCount: Int

    init(text: String) {
        let lines = text.components(separatedBy: "\n")
        let maxLines = PickyAgentResponsePreview.codeBlockMaxLines
        let isTruncated = maxLines > 0 && lines.count > maxLines
        displayText = isTruncated ? lines.prefix(maxLines).joined(separator: "\n") : text
        omittedCount = isTruncated ? lines.count - maxLines : 0
        super.init(frame: .zero)

        textView.fillsAvailableWidth = false
        textView.textContainerInset = .zero
        textView.drawsBackground = false
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: displayText.isEmpty ? " " : displayText,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: PickyHUDTypography.Size.supporting, weight: .regular),
                .foregroundColor: NSColor(DS.Colors.codeText)
            ]
        ))
        addSubview(textView)

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
        let textCap = max(0, cap - 2 * Metrics.padding)
        textView.hugContentMaxWidth = textCap
        let textSize = textView.measureUsedSize(forWidth: textCap)
        let omittedHeight = omittedCount > 0 ? Metrics.omittedHeight : 0
        let measuredWidth = min(cap, ceil(textSize.width) + 2 * Metrics.padding)
        let measuredHeight = Metrics.padding + ceil(textSize.height) + Metrics.padding + omittedHeight
        return NSSize(width: measuredWidth, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let textHeight = textView.measureUsedSize(forWidth: max(0, bounds.width - 2 * Metrics.padding)).height
        textView.frame = NSRect(
            x: Metrics.padding,
            y: Metrics.padding,
            width: max(0, bounds.width - 2 * Metrics.padding),
            height: ceil(textHeight)
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
        static let padding: CGFloat = 8
        static let rowSpacing: CGFloat = 3
        static let cornerRadius: CGFloat = 7
    }

    private let headerField = NSTextField(labelWithString: "")
    private let bodyField = NSTextField(labelWithString: "")

    init(headers: [String], rows: [[String]]) {
        super.init(frame: .zero)
        configure(field: headerField, font: NSFont.systemFont(ofSize: PickyHUDTypography.Size.supporting, weight: .semibold), color: NSColor(DS.Colors.textPrimary))
        configure(field: bodyField, font: NSFont.monospacedSystemFont(ofSize: PickyHUDTypography.Size.supporting, weight: .regular), color: NSColor(DS.Colors.textPrimary.opacity(0.92)))
        headerField.stringValue = headers.joined(separator: " · ")
        bodyField.stringValue = rows.map { $0.joined(separator: " · ") }.joined(separator: "\n")
        bodyField.isHidden = rows.isEmpty
        addSubview(headerField)
        addSubview(bodyField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func computeMeasuredSize(forWidth width: CGFloat) -> NSSize {
        let cap = max(0, width)
        guard cap > 0 else { return .zero }
        let textCap = max(0, cap - 2 * Metrics.padding)
        let headerSize = headerField.attributedStringValue.boundingRect(
            with: NSSize(width: textCap, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let bodySize = bodyField.isHidden ? .zero : bodyField.attributedStringValue.boundingRect(
            with: NSSize(width: textCap, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let contentWidth = max(ceil(headerSize.width), ceil(bodySize.width))
        let bodySpacing = bodyField.isHidden ? 0 : Metrics.rowSpacing
        return NSSize(
            width: min(cap, contentWidth + 2 * Metrics.padding),
            height: Metrics.padding + ceil(headerSize.height) + bodySpacing + ceil(bodySize.height) + Metrics.padding
        )
    }

    override func layout() {
        super.layout()
        let textWidth = max(0, bounds.width - 2 * Metrics.padding)
        let headerHeight = ceil(headerField.attributedStringValue.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        headerField.frame = NSRect(x: Metrics.padding, y: Metrics.padding, width: textWidth, height: headerHeight)
        if !bodyField.isHidden {
            bodyField.frame = NSRect(
                x: Metrics.padding,
                y: Metrics.padding + headerHeight + Metrics.rowSpacing,
                width: textWidth,
                height: max(0, bounds.height - Metrics.padding * 2 - headerHeight - Metrics.rowSpacing)
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius)
        NSColor(DS.Colors.surface2).setFill()
        path.fill()
    }

    private func configure(field: NSTextField, font: NSFont, color: NSColor) {
        field.font = font
        field.textColor = color
        field.backgroundColor = .clear
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
    }
}
