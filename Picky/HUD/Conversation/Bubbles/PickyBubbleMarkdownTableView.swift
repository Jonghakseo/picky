//
//  PickyBubbleMarkdownTableView.swift
//  Picky
//
//  Markdown tables inside conversation bubbles. Columns are sized the way a
//  browser sizes an auto-layout table: never narrower than the longest word,
//  never wider than the one-line text, and the bubble width is shared out in
//  between. A table with four or more columns that does not fit a narrow
//  bubble switches to one card per row instead of scrolling sideways.
//

import AppKit
import SwiftUI

/// Pure sizing rules for bubble tables, kept apart from AppKit views.
enum PickyMarkdownTableLayoutPolicy {
    static let cardMinimumColumnCount = 4
    static let cardBubbleWidthThreshold: CGFloat = 440

    /// Width per column for `available` points. `minimum` is each column's
    /// longest unbreakable word, `maximum` its widest one-line cell. Columns
    /// keep their one-line width when everything fits; otherwise the space
    /// above the minimums is shared in proportion to how much each column
    /// would still like to grow. When even the minimums overflow, the
    /// minimums are returned and the caller scrolls horizontally.
    static func columnWidths(minimum: [CGFloat], maximum: [CGFloat], available: CGFloat) -> [CGFloat] {
        let maximum = zip(minimum, maximum).map { max($0, $1) }
        let maxTotal = maximum.reduce(0, +)
        let minTotal = minimum.reduce(0, +)
        guard available < maxTotal else { return maximum }
        guard available > minTotal, maxTotal > minTotal else { return minimum }
        let ratio = (available - minTotal) / (maxTotal - minTotal)
        return zip(minimum, maximum).map { floor($0 + ($1 - $0) * ratio) }
    }

    /// Wide tables become per-row cards when the bubble is narrow or the
    /// grid could not show every column without sideways scrolling.
    static func usesCards(columnCount: Int, minimumTotalWidth: CGFloat, available: CGFloat, scale: CGFloat) -> Bool {
        guard columnCount >= cardMinimumColumnCount else { return false }
        return available < cardBubbleWidthThreshold * scale || minimumTotalWidth > available
    }

    /// A first column of short values ("1", "A2") reads as a row index, so
    /// cards fold it into the title together with the next column.
    static func firstColumnIsIndex(rows: [[String]]) -> Bool {
        !rows.isEmpty && rows.allSatisfy { row in
            let value = (row.first ?? "").trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && value.count <= 3
        }
    }
}

final class PickyTableMarkdownBlockView: PickyMarkdownBlockNSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 7
        static let slowTableLayoutLogThreshold: TimeInterval = 0.05
    }

    private let headers: [String]
    private let rows: [[String]]
    private let alignments: [PickyMarkdownTableAlignment]
    private let scrollView = NSScrollView()
    private let gridView: GridDocumentView
    /// Built on first use; most tables never need the card form.
    private var cardListStorage: CardListView?
    private var cardListView: CardListView {
        if let cardListStorage { return cardListStorage }
        let view = CardListView(headers: headers, rows: rows)
        addSubview(view)
        cardListStorage = view
        return view
    }
    private let minimumColumnWidths: [CGFloat]
    private let maximumColumnWidths: [CGFloat]
    private var layoutCache: [CGFloat: TableLayout] = [:]
    private var showsCards = false

    private enum TableLayout {
        case grid(columnWidths: [CGFloat], rowHeights: [CGFloat], size: NSSize)
        case cards(CardListView.Layout)

        var size: NSSize {
            switch self {
            case .grid(_, _, let size): size
            case .cards(let layout): layout.size
            }
        }
    }

    init(headers: [String], rows: [[String]], alignments: [PickyMarkdownTableAlignment] = []) {
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
        gridView = GridDocumentView(headers: headers, rows: rows, alignments: alignments)
        let padding = 2 * GridDocumentView.horizontalPadding
        minimumColumnWidths = gridView.minimumContentWidths().map { $0 + padding }
        maximumColumnWidths = gridView.naturalContentWidths().map { $0 + padding }
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
        let size = tableLayout(forWidth: cap).size
        return NSSize(width: min(cap, size.width), height: size.height)
    }

    override func layout() {
        super.layout()
        switch tableLayout(forWidth: bounds.width) {
        case .grid(let columnWidths, let rowHeights, let size):
            showsCards = false
            scrollView.isHidden = false
            cardListStorage?.isHidden = true
            scrollView.frame = bounds
            gridView.frame = NSRect(origin: .zero, size: size)
            gridView.apply(columnWidths: columnWidths, rowHeights: rowHeights)
        case .cards(let layout):
            showsCards = true
            scrollView.isHidden = true
            cardListView.isHidden = false
            cardListView.frame = NSRect(origin: .zero, size: layout.size)
            cardListView.apply(layout)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Cards paint their own backgrounds; only the grid sits on a panel.
        guard !showsCards else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius)
        NSColor(DS.Colors.surface2).setFill()
        path.fill()
        NSColor(DS.Colors.borderSubtle).setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }

    private var columnCount: Int { headers.count }

    private func tableLayout(forWidth available: CGFloat) -> TableLayout {
        let key = available.rounded()
        if let cached = layoutCache[key] { return cached }
        let startedAt = Date()
        let layout: TableLayout
        if PickyMarkdownTableLayoutPolicy.usesCards(
            columnCount: columnCount,
            minimumTotalWidth: minimumColumnWidths.reduce(0, +),
            available: available,
            scale: PickyAppFontScaleStore.staticCGScale
        ) {
            layout = .cards(cardListView.layout(forWidth: available))
        } else {
            let columnWidths = PickyMarkdownTableLayoutPolicy.columnWidths(
                minimum: minimumColumnWidths,
                maximum: maximumColumnWidths,
                available: available
            )
            let rowHeights = gridView.measureRowHeights(columnWidths: columnWidths)
            layout = .grid(
                columnWidths: columnWidths,
                rowHeights: rowHeights,
                size: NSSize(width: columnWidths.reduce(0, +), height: rowHeights.reduce(0, +))
            )
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Metrics.slowTableLayoutLogThreshold {
            PickyLog.noticeRateLimited(
                .markdown,
                key: "markdown.bubble.table-layout",
                cooldown: 5,
                prefix: "🧾 Picky markdown —",
                message: "bubble table layout slow durationMs=\(Self.milliseconds(elapsed)) columns=\(columnCount) rows=\(rows.count) availableWidth=\(Int(available.rounded())) layoutWidth=\(Int(layout.size.width.rounded())) layoutHeight=\(Int(layout.size.height.rounded()))"
            )
        }
        layoutCache[key] = layout
        return layout
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }

    // MARK: - Grid

    private final class GridDocumentView: NSView {
        static let horizontalPadding: CGFloat = 8
        private enum Metrics {
            static let verticalPadding: CGFloat = 6
            static let minRowHeight: CGFloat = 28
            static let separatorWidth: CGFloat = 0.5
        }

        private var columnWidths: [CGFloat] = []
        private let cellFields: [[NSTextField]]
        private var rowHeights: [CGFloat] = []

        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }

        init(headers: [String], rows: [[String]], alignments: [PickyMarkdownTableAlignment]) {
            let tableRows = [headers] + rows
            self.cellFields = tableRows.enumerated().map { rowIndex, cells in
                cells.enumerated().map { columnIndex, text in
                    PickyBubbleMarkdownTableCell.makeField(
                        text: text,
                        isHeader: rowIndex == 0,
                        alignment: alignments.indices.contains(columnIndex) ? alignments[columnIndex] : .leading
                    )
                }
            }
            super.init(frame: .zero)
            cellFields.flatMap { $0 }.forEach { addSubview($0) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        private var columnCount: Int { cellFields.first?.count ?? 0 }

        func naturalContentWidths() -> [CGFloat] {
            (0..<columnCount).map { column in
                cellFields.compactMap { $0.indices.contains(column) ? $0[column] : nil }
                    .map(PickyBubbleMarkdownTableCell.naturalWidth(for:))
                    .max() ?? 0
            }
        }

        func minimumContentWidths() -> [CGFloat] {
            (0..<columnCount).map { column in
                cellFields.compactMap { $0.indices.contains(column) ? $0[column] : nil }
                    .map { PickyBubbleMarkdownTableCell.minimumWidth(for: $0.attributedStringValue) }
                    .max() ?? 0
            }
        }

        func measureRowHeights(columnWidths: [CGFloat]) -> [CGFloat] {
            cellFields.map { row in
                let maxCellHeight = row.enumerated().map { columnIndex, field in
                    let columnWidth = columnWidths.indices.contains(columnIndex) ? columnWidths[columnIndex] : columnWidths.last ?? 160
                    let textWidth = max(1, columnWidth - 2 * Self.horizontalPadding)
                    let contentHeight = PickyBubbleMarkdownTableCell.measuredContentHeight(
                        for: field,
                        width: textWidth
                    )
                    return ceil(contentHeight) + 2 * Metrics.verticalPadding
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
    }

    // MARK: - Cards

    /// One card per data row: a bold title, then "header  value" lines.
    private final class CardListView: NSView {
        private enum Metrics {
            static let padding: CGFloat = 9
            static let cardGap: CGFloat = 6
            static let lineGap: CGFloat = 4
            static let labelGap: CGFloat = 8
            static let maxLabelFraction: CGFloat = 0.4
            static let cornerRadius: CGFloat = 7
        }

        struct Layout {
            var size: NSSize
            var cardRects: [NSRect]
            var fieldFrames: [[NSRect]]
        }

        private let titleUsesIndex: Bool
        private let detailColumns: [Int]
        /// Per card: title field first, then (label, value) pairs.
        private let cardFields: [[NSTextField]]
        private var cardRects: [NSRect] = []

        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }

        init(headers: [String], rows: [[String]]) {
            let titleUsesIndex = headers.count > 1 && PickyMarkdownTableLayoutPolicy.firstColumnIsIndex(rows: rows)
            let detailColumns = Array((titleUsesIndex ? 2 : 1)..<max(headers.count, titleUsesIndex ? 2 : 1))
            self.titleUsesIndex = titleUsesIndex
            self.detailColumns = detailColumns
            self.cardFields = rows.map { row in
                func cell(_ index: Int) -> String { row.indices.contains(index) ? row[index] : "" }
                let title = titleUsesIndex ? "\(cell(0)). \(cell(1))" : cell(0)
                var fields = [PickyBubbleMarkdownTableCell.makeField(text: title, isHeader: true)]
                for column in detailColumns {
                    fields.append(PickyBubbleMarkdownTableCell.makeCardLabelField(text: headers[column]))
                    fields.append(PickyBubbleMarkdownTableCell.makeField(text: cell(column), isHeader: false))
                }
                return fields
            }
            super.init(frame: .zero)
            cardFields.flatMap { $0 }.forEach { addSubview($0) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func layout(forWidth width: CGFloat) -> Layout {
            let inner = max(1, width - 2 * Metrics.padding)
            let labelWidth = min(
                inner * Metrics.maxLabelFraction,
                cardFields.first.map { fields in
                    stride(from: 1, to: fields.count, by: 2)
                        .map { PickyBubbleMarkdownTableCell.naturalWidth(for: fields[$0]) }
                        .max() ?? 0
                } ?? 0
            )
            let valueX = Metrics.padding + labelWidth + Metrics.labelGap
            let valueWidth = max(1, width - valueX - Metrics.padding)

            var y: CGFloat = 0
            var rects: [NSRect] = []
            var frames: [[NSRect]] = []
            for (cardIndex, fields) in cardFields.enumerated() {
                if cardIndex > 0 { y += Metrics.cardGap }
                var cardFrames: [NSRect] = []
                var cursor = y + Metrics.padding
                let titleHeight = ceil(PickyBubbleMarkdownTableCell.measuredContentHeight(for: fields[0], width: inner))
                cardFrames.append(NSRect(x: Metrics.padding, y: cursor, width: inner, height: titleHeight))
                cursor += titleHeight
                for pair in stride(from: 1, to: fields.count, by: 2) {
                    let label = fields[pair]
                    let value = fields[pair + 1]
                    cursor += Metrics.lineGap
                    let valueHeight = ceil(PickyBubbleMarkdownTableCell.measuredContentHeight(for: value, width: valueWidth))
                    let labelHeight = ceil(PickyBubbleMarkdownTableCell.measuredContentHeight(for: label, width: labelWidth))
                    // Sit the smaller label on the value's first baseline.
                    let baselineOffset = max(0, PickyBubbleMarkdownTableCell.firstBaseline(of: value.attributedStringValue)
                        - PickyBubbleMarkdownTableCell.firstBaseline(of: label.attributedStringValue))
                    cardFrames.append(NSRect(x: Metrics.padding, y: cursor + baselineOffset, width: labelWidth, height: labelHeight))
                    cardFrames.append(NSRect(x: valueX, y: cursor, width: valueWidth, height: valueHeight))
                    cursor += max(valueHeight, labelHeight + baselineOffset)
                }
                cursor += Metrics.padding
                rects.append(NSRect(x: 0, y: y, width: width, height: cursor - y))
                frames.append(cardFrames)
                y = cursor
            }
            return Layout(size: NSSize(width: width, height: y), cardRects: rects, fieldFrames: frames)
        }

        func apply(_ layout: Layout) {
            cardRects = layout.cardRects
            for (fields, frames) in zip(cardFields, layout.fieldFrames) {
                for (field, frame) in zip(fields, frames) { field.frame = frame }
            }
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            for rect in cardRects {
                let path = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.4, dy: 0.4),
                    xRadius: Metrics.cornerRadius,
                    yRadius: Metrics.cornerRadius
                )
                NSColor(DS.Colors.surface2).setFill()
                path.fill()
                NSColor(DS.Colors.borderSubtle).setStroke()
                path.lineWidth = 0.8
                path.stroke()
            }
        }
    }
}

/// Builds the selectable label used for one markdown table cell inside a
/// conversation bubble.
enum PickyBubbleMarkdownTableCell {
    static func makeField(
        text: String,
        isHeader: Bool,
        alignment: PickyMarkdownTableAlignment = .leading
    ) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        configure(field)
        field.alignment = alignment.textAlignment
        field.attributedStringValue = attributedString(text, isHeader: isHeader, alignment: alignment)
        return field
    }

    /// Column name shown beside each value in card mode.
    static func makeCardLabelField(text: String) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        configure(field)
        let attr = NSMutableAttributedString(attributedString: attributedString(text, isHeader: false))
        let full = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.font, value: NSFont.systemFont(ofSize: PickyHUDTypography.Size.meta, weight: .medium), range: full)
        attr.addAttribute(.foregroundColor, value: NSColor(DS.Colors.textTertiary), range: full)
        field.attributedStringValue = attr
        return field
    }

    private static func configure(_ field: NSTextField) {
        field.backgroundColor = .clear
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = true
        // Clicking a selectable field installs the shared field editor. With
        // rich text disabled that editor runs in plain-text mode and repaints
        // the whole string with the *cell's* font and alignment, which setting
        // `attributedStringValue` never updates — so a cell holding monospaced
        // or bold runs visibly resized the moment it was clicked.
        field.allowsEditingTextAttributes = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
    }

    /// Measure with the same cell that paints the unfocused field. A raw
    /// attributed-string bounding rect can disagree with the cell's wrapping
    /// and clip the final line until AppKit installs the field editor.
    static func measuredContentHeight(for field: NSTextField, width: CGFloat) -> CGFloat {
        guard let cell = field.cell else { return 0 }
        return cell.cellSize(
            forBounds: NSRect(
                x: 0,
                y: 0,
                width: max(1, width),
                height: CGFloat.greatestFiniteMagnitude
            )
        ).height
    }

    /// One-line width as the cell paints it. The cell adds text-container
    /// padding that `boundingRect` leaves out; sizing a column from the
    /// bounding rect wrapped the last syllable of short cells ("내부 모/듈").
    static func naturalWidth(for field: NSTextField) -> CGFloat {
        guard let cell = field.cell else { return 0 }
        return ceil(cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ).width)
    }

    /// Width of the longest piece the typesetter will not break: UAX #14
    /// line-break units, with Hangul syllables glued back into the
    /// space-delimited words that `hangulWordPriority` keeps together.
    static func minimumWidth(for attributed: NSAttributedString) -> CGFloat {
        let string = attributed.string as NSString
        guard string.length > 0 else { return 0 }
        let tokenizer = CFStringTokenizerCreate(
            nil,
            attributed.string as CFString,
            CFRange(location: 0, length: string.length),
            kCFStringTokenizerUnitLineBreak,
            nil
        )
        var units: [NSRange] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let range = NSRange(location: token.location, length: token.length)
            if let last = units.last {
                let previous = string.substring(with: last)
                let next = string.substring(with: range)
                if previous.last?.isWhitespace == false, isHangul(previous.last) || isHangul(next.first) {
                    units[units.count - 1] = NSUnionRange(last, range)
                    continue
                }
            }
            units.append(range)
        }

        let probe = NSTextField(labelWithString: "")
        configure(probe)
        var widest: CGFloat = 0
        for range in units {
            let unit = attributed.attributedSubstring(from: range)
            let trimmed = unit.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            probe.attributedStringValue = unit.attributedSubstring(from: (unit.string as NSString).range(of: trimmed))
            widest = max(widest, naturalWidth(for: probe))
        }
        return widest
    }

    private static func isHangul(_ character: Character?) -> Bool {
        guard let value = character?.unicodeScalars.first?.value else { return false }
        return (0xAC00...0xD7A3).contains(value)
            || (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value)
    }

    /// Distance from the top of the text to the first baseline.
    static func firstBaseline(of attributed: NSAttributedString) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return lineRect.minY + layoutManager.location(forGlyphAt: 0).y
    }

    static func attributedString(
        _ text: String,
        isHeader: Bool,
        alignment: PickyMarkdownTableAlignment = .leading
    ) -> NSAttributedString {
        let content = text.isEmpty ? " " : text
        let attr = NSMutableAttributedString(
            attributedString: PickyMarkdownInlineTextView.buildAttributedString(from: [.paragraph(content)])
        )
        let full = NSRange(location: 0, length: attr.length)
        if alignment != .leading {
            attr.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.alignment = alignment.textAlignment
                attr.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        // Data cells keep the inline renderer's own colors: body at textBody,
        // bold at textPrimary, code and links at their semantic tints. A
        // blanket foreground override used to flatten all four into one color.
        guard isHeader else { return attr }

        // Header cells read as a single label, so every run steps up to
        // semibold and to the brighter primary color — except code and link
        // runs, which keep their tint so the semantics survive in a header too.
        attr.enumerateAttributes(in: full) { attributes, range, _ in
            let current = attributes[.font] as? NSFont
                ?? NSFont.systemFont(ofSize: PickyHUDTypography.Size.body)
            let isMonospaced = current.fontDescriptor.symbolicTraits.contains(.monoSpace)
            attr.addAttribute(
                .font,
                value: isMonospaced
                    ? NSFont.monospacedSystemFont(ofSize: current.pointSize, weight: .semibold)
                    : NSFont.systemFont(ofSize: current.pointSize, weight: .semibold),
                range: range
            )
            if attributes[.link] == nil, !isMonospaced {
                attr.addAttribute(.foregroundColor, value: NSColor(DS.Colors.textPrimary), range: range)
            }
        }
        return attr
    }
}

private extension PickyMarkdownTableAlignment {
    var textAlignment: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }
}
