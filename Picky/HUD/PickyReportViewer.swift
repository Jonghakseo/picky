//
//  PickyReportViewer.swift
//  Picky
//
//  In-app Markdown report viewer for Picky session artifacts.
//

import AppKit
import Combine
import Foundation
import SwiftUI

struct PickyReportMarkdownRenderer {
    private static let slowBlockParseLogThreshold: TimeInterval = 0.05

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case table(headers: [String], rows: [[String]])
        case codeBlock(String)
    }

    func blocks(from markdown: String) -> [Block] {
        let key = markdown as NSString
        if let cached = Self.blockCache.object(forKey: key) {
            return cached.blocks
        }
        let startedAt = Date()
        let computed = computeBlocks(from: markdown)
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Self.slowBlockParseLogThreshold {
            Self.logSlowMarkdownWork(
                name: "markdown blocks parse slow",
                duration: elapsed,
                details: "markdownChars=\(markdown.count) blocks=\(computed.count)"
            )
        }
        Self.blockCache.setObject(BlockCacheEntry(blocks: computed), forKey: key, cost: markdown.utf8.count)
        return computed
    }

    private func computeBlocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var openingFenceLength: Int?
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0

        func flushParagraph() {
            let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraphLines.removeAll()
        }

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let requiredFenceLength = openingFenceLength {
                if line.allSatisfy({ $0 == "`" }), line.count >= requiredFenceLength {
                    blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    openingFenceLength = nil
                } else {
                    codeLines.append(rawLine)
                }
                index += 1
                continue
            }

            let fenceLength = line.prefix(while: { $0 == "`" }).count
            if fenceLength >= 3 {
                flushParagraph()
                openingFenceLength = fenceLength
                index += 1
                continue
            }

            if let table = parseTable(lines: lines, startingAt: index) {
                flushParagraph()
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }

            if line.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = parseHeading(line) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                index += 1
                continue
            }

            paragraphLines.append(rawLine)
            index += 1
        }

        if openingFenceLength != nil {
            blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    func inlineAttributedString(for markdown: String) -> AttributedString {
        let key = markdown as NSString
        if let cached = Self.inlineCache.object(forKey: key) {
            return cached.value
        }
        let value = computeInlineAttributedString(for: markdown)
        Self.inlineCache.setObject(InlineCacheEntry(value: value), forKey: key, cost: markdown.utf8.count)
        return value
    }

    private func computeInlineAttributedString(for markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            return attributed
        }
        return AttributedString(markdown)
    }

    private func parseTable(lines: [String], startingAt index: Int) -> (block: Block, nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headerCells = parsePipeRow(lines[index]),
              let separatorCells = parsePipeRow(lines[index + 1]),
              isTableSeparator(cells: separatorCells) else { return nil }
        let columnCount = max(headerCells.count, separatorCells.count)
        guard columnCount >= 2 else { return nil }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count {
            let line = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let cells = parsePipeRow(lines[nextIndex]) else { break }
            if isTableSeparator(cells: cells) { break }
            rows.append(normalizedCells(cells, count: columnCount))
            nextIndex += 1
        }

        return (.table(headers: normalizedCells(headerCells, count: columnCount), rows: rows), nextIndex)
    }

    private func parsePipeRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return nil }
        var body = trimmed
        if body.first == "|" { body.removeFirst() }
        if body.last == "|" { body.removeLast() }
        let cells = body.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return cells.count >= 2 ? cells : nil
    }

    private func isTableSeparator(cells: [String]) -> Bool {
        cells.count >= 2 && cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: " ", with: "")
            guard stripped.count >= 3 else { return false }
            let core = stripped.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }

    private func normalizedCells(_ cells: [String], count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count < count { return cells + Array(repeating: "", count: count - cells.count) }
        return Array(cells.prefix(count - 1)) + [cells.dropFirst(count - 1).joined(separator: " | ")]
    }

    private func parseHeading(_ line: String) -> Block? {
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard markerCount > 0, markerCount <= 6 else { return nil }
        let remainder = line.dropFirst(markerCount)
        guard remainder.first == " " else { return nil }
        let text = remainder.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return .heading(level: markerCount, text: text)
    }

    // Shared across all renderer instances. NSCache is thread-safe and evicts under memory pressure.
    private static let blockCache: NSCache<NSString, BlockCacheEntry> = {
        let cache = NSCache<NSString, BlockCacheEntry>()
        cache.countLimit = 256
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    private static let inlineCache: NSCache<NSString, InlineCacheEntry> = {
        let cache = NSCache<NSString, InlineCacheEntry>()
        cache.countLimit = 1024
        cache.totalCostLimit = 1 * 1024 * 1024
        return cache
    }()

    private static func logSlowMarkdownWork(name: String, duration: TimeInterval, details: String) {
        PickyLog.noticeRateLimited(
            .markdown,
            key: "markdown.renderer.\(name)",
            cooldown: 5,
            prefix: "🧾 Picky markdown —",
            message: "\(name) durationMs=\(milliseconds(duration)) \(details)"
        )
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }

    private final class BlockCacheEntry {
        let blocks: [Block]
        init(blocks: [Block]) { self.blocks = blocks }
    }

    private final class InlineCacheEntry {
        let value: AttributedString
        init(value: AttributedString) { self.value = value }
    }
}

/// Stable, presentation-ready identity for a parsed report block. The identity
/// combines its source index with a deterministic content hash so navigation can
/// survive a report refresh when the nearby block did not change.
struct PickyReportBlockPresentation: Identifiable, Equatable {
    let id: String
    let block: PickyReportMarkdownRenderer.Block
    let plainText: String

    static func blocks(from markdown: String, renderer: PickyReportMarkdownRenderer = PickyReportMarkdownRenderer()) -> [Self] {
        renderer.blocks(from: markdown).enumerated().map { index, block in
            Self(index: index, block: block, renderer: renderer)
        }
    }

    init(index: Int, block: PickyReportMarkdownRenderer.Block, renderer: PickyReportMarkdownRenderer = PickyReportMarkdownRenderer()) {
        self.id = "report-block-\(index)-\(Self.stableHash(for: Self.sourceText(for: block)))"
        self.block = block
        self.plainText = Self.plainText(for: block, renderer: renderer)
    }

    private static func sourceText(for block: PickyReportMarkdownRenderer.Block) -> String {
        switch block {
        case .heading(let level, let text): "heading|\(level)|\(text)"
        case .paragraph(let text): "paragraph|\(text)"
        case .bullet(let text): "bullet|\(text)"
        case .table(let headers, let rows): "table|\(headers.joined(separator: "|"))|\(rows.map { $0.joined(separator: "|") }.joined(separator: "\\n"))"
        case .codeBlock(let text): "code|\(text)"
        }
    }

    private static func plainText(for block: PickyReportMarkdownRenderer.Block, renderer: PickyReportMarkdownRenderer) -> String {
        func rendered(_ markdown: String) -> String {
            String(renderer.inlineAttributedString(for: markdown).characters)
        }

        switch block {
        case .heading(_, let text), .paragraph(let text), .bullet(let text), .codeBlock(let text):
            return rendered(text)
        case .table(let headers, let rows):
            return ([headers] + rows).flatMap { $0 }.map(rendered).joined(separator: " ")
        }
    }

    private static func stableHash(for text: String) -> String {
        // FNV-1a is deliberately deterministic (unlike Swift's randomized
        // `Hasher`) and needs no additional framework dependency.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct PickyReportOutlineEntry: Identifiable, Equatable {
    let id: String
    let level: Int
    let title: String

    static func entries(from blocks: [PickyReportBlockPresentation]) -> [Self] {
        blocks.compactMap { block in
            guard case .heading(let level, let title) = block.block, (1...3).contains(level) else { return nil }
            return Self(id: block.id, level: level, title: title)
        }
    }
}

struct PickyReportSearchState: Equatable {
    private(set) var query = ""
    private(set) var matches: [String] = []
    private(set) var currentIndex: Int?

    var currentMatchID: String? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    mutating func update(query: String, in blocks: [PickyReportBlockPresentation]) {
        self.query = query
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = term.isEmpty ? [] : blocks.compactMap { block in
            block.plainText.localizedCaseInsensitiveContains(term) ? block.id : nil
        }
        currentIndex = matches.isEmpty ? nil : 0
    }

    mutating func selectNext() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? -1) + 1) % matches.count
    }

    mutating func selectPrevious() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? 0) - 1 + matches.count) % matches.count
    }
}

enum PickyReportOutlinePresentationMode: Equatable {
    case pushed
    case overlay
}

/// Keeps the report's readable text column at or above 500pt when the outline
/// occupies layout space. The 48pt content inset and 1pt divider are included
/// so this policy reflects the actual column available to report prose.
enum PickyReportOutlineLayoutPolicy {
    static let sidebarWidth: CGFloat = 192
    static let contentHorizontalInsets: CGFloat = 48
    static let dividerWidth: CGFloat = 1
    static let minimumReadingColumnWidth: CGFloat = 500

    static let minimumPushedViewerWidth = sidebarWidth + dividerWidth + contentHorizontalInsets + minimumReadingColumnWidth

    static func presentationMode(forViewerWidth width: CGFloat) -> PickyReportOutlinePresentationMode {
        width >= minimumPushedViewerWidth ? .pushed : .overlay
    }

    static func readingColumnWidth(forPushedViewerWidth width: CGFloat) -> CGFloat {
        max(0, width - sidebarWidth - dividerWidth - contentHorizontalInsets)
    }
}

private struct PickyReportBlockPosition: Equatable {
    let id: String
    let minY: CGFloat
    let isHeading: Bool
}

private struct PickyReportBlockPositionPreferenceKey: PreferenceKey {
    static var defaultValue: [PickyReportBlockPosition] = []

    static func reduce(value: inout [PickyReportBlockPosition], nextValue: () -> [PickyReportBlockPosition]) {
        value.append(contentsOf: nextValue())
    }
}

private enum PickyReportScrollCoordinateSpace {
    static let name = "PickyReportScrollCoordinateSpace"
}

struct PickyMarkdownReportView: View {
    let blocks: [PickyReportBlockPresentation]
    /// Multiplier applied to every font size in this view. 1.0 maps to the report's
    /// readable defaults; ⌘+ / ⌘- on the report panel update the model and re-render
    /// this view at the new scale.
    var fontScale: Double = 1.0
    var matchingBlockIDs: Set<String> = []
    var currentMatchID: String?
    /// Global app font scale (⌘+ / ⌘- when no detached panel has focus). Composed
    /// multiplicatively with the per-panel `fontScale` so a user who set the app
    /// to 110% and the panel to 130% sees 143% on the report body. Declared as an
    /// `@Environment` value so the view re-renders the moment the root container
    /// publishes a new app scale.
    @Environment(\.pickyAppFontScale) private var appFontScale
    private let renderer = PickyReportMarkdownRenderer()
    /// Width of the content column, measured from the enclosing scroll view so
    /// tables can size their columns to the text they hold and spend any slack
    /// on the columns that actually need it instead of a fixed per-column floor.
    @State private var containerWidth: CGFloat = 0

    /// Body copy size at scale 1.0. Bumped from the original 13.5pt because users
    /// reported the dense report column was hard to read at default macOS Retina
    /// scaling. Heading sizes derive from this so the type ladder stays balanced.
    private static let bodyBaseSize: CGFloat = 15
    private static let codeBaseSize: CGFloat = 14
    private static let slowTableWidthLogThreshold: TimeInterval = 0.05

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { presentation in
                reportBlockView(presentation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in containerWidth = newValue }
            }
        )
        .textSelection(.enabled)
    }

    private func reportBlockView(_ presentation: PickyReportBlockPresentation) -> some View {
        blockView(presentation.block)
            .id(presentation.id)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PickyReportBlockPositionPreferenceKey.self,
                        value: [
                            PickyReportBlockPosition(
                                id: presentation.id,
                                minY: proxy.frame(in: .named(PickyReportScrollCoordinateSpace.name)).minY.rounded(),
                                isHeading: isHeading(presentation.block)
                            ),
                        ]
                    )
                }
            }
            .background(highlightBackground(for: presentation.id))
    }

    @ViewBuilder
    private func highlightBackground(for id: String) -> some View {
        if id == currentMatchID {
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.16))
        } else if matchingBlockIDs.contains(id) {
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.accentSubtle)
        }
    }

    private func isHeading(_ block: PickyReportMarkdownRenderer.Block) -> Bool {
        if case .heading = block { return true }
        return false
    }

    @ViewBuilder
    private func blockView(_ block: PickyReportMarkdownRenderer.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(font(forHeadingLevel: level))
                .fontWeight(level == 1 ? .semibold : .medium)
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(.top, level == 1 ? 2 : 8)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(.system(size: scaled(Self.bodyBaseSize), weight: .regular, design: .default))
                .foregroundStyle(DS.Colors.textPrimary.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: scaled(Self.bodyBaseSize), weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(renderer.inlineAttributedString(for: text))
                    .font(.system(size: scaled(Self.bodyBaseSize), weight: .regular, design: .default))
                    .foregroundStyle(DS.Colors.textPrimary.opacity(0.92))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .codeBlock(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: scaled(Self.codeBaseSize), weight: .regular, design: .monospaced))
                    .foregroundStyle(DS.Colors.codeText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let widths = tableColumnWidths(headers: headers, rows: rows, availableWidth: containerWidth)
        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, widths: widths, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, widths: widths, isHeader: false)
                }
            }
            .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
        }
    }

    private func tableRow(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(renderer.inlineAttributedString(for: cell.isEmpty ? " " : cell))
                    .font(.system(size: scaled(Self.bodyBaseSize - 1), weight: isHeader ? .semibold : .regular, design: .default))
                    .foregroundStyle(isHeader ? DS.Colors.textPrimary : DS.Colors.textPrimary.opacity(0.92))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: widths[index], alignment: .topLeading)
            }
        }
        .background(isHeader ? DS.Colors.surface3.opacity(0.72) : DS.Colors.surface2.opacity(0.38))
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Colors.borderSubtle).frame(height: 0.5) }
        .overlay(alignment: .topLeading) {
            GeometryReader { _ in
                ForEach(Array(tableSeparatorOffsets(widths: widths).enumerated()), id: \.offset) { _, offset in
                    Rectangle()
                        .fill(DS.Colors.borderSubtle)
                        .frame(width: 0.5)
                        .offset(x: offset)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Content-driven column widths. Each column is measured against the widest
    /// single-line cell it holds (capped so a long cell wraps instead of
    /// stretching the table). When the table is narrower than the available
    /// width, the slack is handed to the columns whose text was clipped by the
    /// cap, so short columns stay tight rather than sharing a fixed floor.
    private func tableColumnWidths(headers: [String], rows: [[String]], availableWidth: CGFloat) -> [CGFloat] {
        let startedAt = Date()
        let widths = computeTableColumnWidths(headers: headers, rows: rows, availableWidth: availableWidth)
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Self.slowTableWidthLogThreshold {
            PickyLog.noticeRateLimited(
                .markdown,
                key: "markdown.report.table-widths",
                cooldown: 5,
                prefix: "🧾 Picky markdown —",
                message: "report table widths slow durationMs=\(Self.milliseconds(elapsed)) columns=\(headers.count) rows=\(rows.count) availableWidth=\(Int(availableWidth.rounded()))"
            )
        }
        return widths
    }

    private func computeTableColumnWidths(headers: [String], rows: [[String]], availableWidth: CGFloat) -> [CGFloat] {
        let columnCount = headers.count
        guard columnCount > 0 else { return [] }
        let horizontalPadding: CGFloat = 20
        let maxColumnWidth = scaled(360)
        let minColumnWidth = scaled(44)
        let bodyFont = NSFont.systemFont(ofSize: scaled(Self.bodyBaseSize - 1))
        let headerFont = NSFont.systemFont(ofSize: scaled(Self.bodyBaseSize - 1), weight: .semibold)

        func textWidth(_ text: String, font: NSFont) -> CGFloat {
            let content = text.isEmpty ? " " : text
            return content.components(separatedBy: "\n").reduce(CGFloat(0)) { widest, line in
                max(widest, (line as NSString).size(withAttributes: [.font: font]).width)
            }
        }

        var uncapped = [CGFloat](repeating: 0, count: columnCount)
        for column in 0..<columnCount {
            var widest = textWidth(headers[column], font: headerFont)
            for row in rows where column < row.count {
                widest = max(widest, textWidth(row[column], font: bodyFont))
            }
            uncapped[column] = ceil(widest) + horizontalPadding
        }

        let capped = uncapped.map { min(max($0, minColumnWidth), maxColumnWidth) }
        let total = capped.reduce(0, +)
        guard availableWidth > total else { return capped }

        let desire = zip(uncapped, capped).map { max($0 - $1, 0) }
        let desireTotal = desire.reduce(0, +)
        guard desireTotal > 0 else { return capped }
        let extra = availableWidth - total
        return zip(capped, desire).map { $0 + extra * ($1 / desireTotal) }
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }

    private func tableSeparatorOffsets(widths: [CGFloat]) -> [CGFloat] {
        var offsets: [CGFloat] = []
        var runningWidth: CGFloat = 0
        for width in widths.dropLast() {
            runningWidth += width
            offsets.append(runningWidth)
        }
        return offsets
    }

    private func font(forHeadingLevel level: Int) -> Font {
        switch level {
        case 1: .system(size: scaled(26), weight: .semibold, design: .rounded)
        case 2: .system(size: scaled(20), weight: .semibold, design: .rounded)
        case 3: .system(size: scaled(17), weight: .semibold, design: .rounded)
        default: .system(size: scaled(15.5), weight: .semibold, design: .rounded)
        }
    }

    private func scaled(_ size: CGFloat) -> CGFloat {
        size * CGFloat(fontScale) * appFontScale
    }
}

@MainActor
protocol PickyReportPresenting: AnyObject {
    func openReport(sessionID: String, title: String, fileURL: URL, markdown: String) throws
}

/// Window-scoped persistence hook so each open report panel can write its zoom
/// level back to the shared settings file the moment the user taps ⌘+ / ⌘-.
/// The presenter wires this to a real `PickySettingsStore`; tests can substitute
/// a no-op closure.
@MainActor
struct PickyMarkdownReportFontScalePersister {
    let load: () -> Double
    let save: (Double) -> Void
}

/// Shared report-viewer preference hook. The latest explicit outline toggle is
/// restored by subsequently opened report panels, including after app relaunch.
@MainActor
struct PickyReportOutlineVisibilityPersister {
    let load: () -> Bool
    let save: (Bool) -> Void
}

@MainActor
final class PickyReportViewerPresenter: PickyReportPresenting {
    static let shared = PickyReportViewerPresenter()

    private struct ReportRecord {
        let panel: NSPanel
        let model: PickyReportViewerModel
        let delegate: PickyReportPanelDelegate
        // Held strongly so the underlying NotificationCenter observers stay
        // alive for the panel's lifetime. Dropping the autosaver tears down
        // observation; never hand it out by reference.
        let frameAutosaver: PickyDetachedPanelFrameAutosaver
    }

    private var records: [String: ReportRecord] = [:]
    /// Held by the presenter for the lifetime of the app once `configure(appearanceStore:)`
    /// runs from `CompanionAppDelegate`. The fallback default keeps unit tests and
    /// previews working without crashing if `configure` was never called.
    private var appearanceStore = PickyAppearanceStore()
    /// Global app font scale shared with the rest of the UI surface so the report
    /// header chrome (header buttons, title) scales together with the HUD/Companion
    /// when the user hits ⌘+ / ⌘-. The per-panel `fontScale` on `PickyReportViewerModel`
    /// still layers on top for fine-grained zoom of the markdown body.
    private var fontScaleStore = PickyAppFontScaleStore()
    /// Shared settings store used to load/persist the markdown report zoom level.
    /// Falls back to the default settings location for tests and previews.
    private var settingsStore = PickySettingsStore()

    private init() {}

    /// Wires the live appearance store so the report panel flips with the rest of
    /// the app. Called once from `CompanionAppDelegate` at startup.
    func configure(
        appearanceStore: PickyAppearanceStore,
        fontScaleStore: PickyAppFontScaleStore,
        settingsStore: PickySettingsStore = PickySettingsStore()
    ) {
        self.appearanceStore = appearanceStore
        self.fontScaleStore = fontScaleStore
        self.settingsStore = settingsStore
    }

    func openReport(sessionID: String, title: String, fileURL: URL, markdown: String) throws {
        if let existing = records[sessionID] {
            existing.model.update(title: title, fileURL: fileURL, markdown: markdown)
            existing.panel.title = "Picky Report — \(title)"
            NSApp.activate(ignoringOtherApps: true)
            existing.panel.orderFrontRegardless()
            existing.panel.makeKey()
            return
        }

        let model = PickyReportViewerModel(
            title: title,
            fileURL: fileURL,
            markdown: markdown,
            fontScalePersister: makeFontScalePersister(),
            outlineVisibilityPersister: makeOutlineVisibilityPersister()
        )
        let panel = PickyReportPanel(
            contentRect: targetFrame(),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Picky Report — \(title)"
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = PickyAppearancePanelChrome.windowBackground()
        panel.minSize = NSSize(width: 620, height: 420)
        // Persist the panel's user-moved frame across launches through
        // PickySettingsStore. Replaces NSWindow.setFrameAutosaveName, which
        // is single-instance and silently no-ops on every report panel after
        // the first when several messages are open as reports simultaneously.
        // The autosaver applies the saved frame to the panel before the
        // window is shown and writes the latest frame back on every move/resize.
        let frameAutosaver = PickyDetachedPanelFrameAutosaver(
            panel: panel,
            persister: PickyDetachedPanelFramePersister.backed(by: settingsStore, kind: .reportViewer)
        )

        let rootView = PickyAppFontScaleRoot(store: fontScaleStore) {
            PickyReportViewerWindowView(model: model)
                .environmentObject(self.appearanceStore)
                .modifier(PickyPreferredColorSchemeModifier(store: self.appearanceStore))
        }
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { rootView })
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        let delegate = PickyReportPanelDelegate { [weak self, weak panel] in
            if let panel { self?.remove(panel: panel) }
        }
        panel.delegate = delegate
        records[sessionID] = ReportRecord(panel: panel, model: model, delegate: delegate, frameAutosaver: frameAutosaver)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func remove(panel: NSPanel) {
        records = records.filter { $0.value.panel !== panel }
    }

    private func makeFontScalePersister() -> PickyMarkdownReportFontScalePersister {
        let store = settingsStore
        return PickyMarkdownReportFontScalePersister(
            load: { store.load().fontScales.markdownReport },
            save: { newScale in
                var current = store.load()
                current.fontScales.markdownReport = PickyFontScales.clamped(newScale)
                try? store.save(current)
            }
        )
    }

    private func makeOutlineVisibilityPersister() -> PickyReportOutlineVisibilityPersister {
        let store = settingsStore
        return PickyReportOutlineVisibilityPersister(
            load: { store.load().reportViewerOutlinePresented },
            save: { isPresented in
                var current = store.load()
                current.reportViewerOutlinePresented = isPresented
                try? store.save(current)
            }
        )
    }

    private func targetFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(CGFloat(860), visibleFrame.width - 48)
        let height = min(CGFloat(680), visibleFrame.height - 48)
        return NSRect(
            x: visibleFrame.maxX - width - 24,
            y: visibleFrame.maxY - height - 24,
            width: width,
            height: height
        )
    }
}

@MainActor
final class PickyReportViewerModel: ObservableObject {
    @Published private(set) var title: String
    @Published private(set) var fileURL: URL
    @Published private(set) var markdown: String
    @Published private(set) var revision = UUID()
    /// Live zoom multiplier for the markdown body. Bound to `PickyFontScales.minimum/maximum`
    /// and rounded to one decimal so ⌘+ taps don't drift due to floating-point.
    @Published private(set) var fontScale: Double
    @Published private(set) var isOutlinePresented: Bool

    private let fontScalePersister: PickyMarkdownReportFontScalePersister?
    private let outlineVisibilityPersister: PickyReportOutlineVisibilityPersister?

    init(
        title: String,
        fileURL: URL,
        markdown: String,
        fontScalePersister: PickyMarkdownReportFontScalePersister? = nil,
        outlineVisibilityPersister: PickyReportOutlineVisibilityPersister? = nil
    ) {
        self.title = title
        self.fileURL = fileURL
        self.markdown = markdown
        self.fontScalePersister = fontScalePersister
        self.outlineVisibilityPersister = outlineVisibilityPersister
        self.fontScale = PickyFontScales.clamped(fontScalePersister?.load() ?? PickyFontScales.defaults.markdownReport)
        self.isOutlinePresented = outlineVisibilityPersister?.load() ?? false
    }

    func update(title: String, fileURL: URL, markdown: String) {
        self.title = title
        self.fileURL = fileURL
        self.markdown = markdown
        self.revision = UUID()
    }

    func zoomIn() { setFontScale(fontScale + PickyFontScales.step) }
    func zoomOut() { setFontScale(fontScale - PickyFontScales.step) }
    func resetZoom() { setFontScale(PickyFontScales.defaults.markdownReport) }

    func toggleOutline() {
        setOutlinePresented(!isOutlinePresented)
    }

    func dismissOutline() {
        setOutlinePresented(false)
    }

    private func setFontScale(_ newValue: Double) {
        let clamped = PickyFontScales.clamped(newValue)
        guard clamped != fontScale else { return }
        fontScale = clamped
        fontScalePersister?.save(clamped)
    }

    private func setOutlinePresented(_ isPresented: Bool) {
        guard isPresented != isOutlinePresented else { return }
        isOutlinePresented = isPresented
        outlineVisibilityPersister?.save(isPresented)
    }
}

struct PickyReportViewerWindowView: View {
    @ObservedObject var model: PickyReportViewerModel
    @State private var didCopyMarkdown = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var isSearchPresented = false
    @State private var searchState = PickyReportSearchState()
    @State private var activeSectionID: String?
    /// Rounded before storage so sub-point AppKit layout updates do not trigger
    /// report-body recomputation while the panel is resized.
    @State private var viewerWidth: CGFloat = 0
    /// The nearest visible block is retained across a streamed report refresh,
    /// then restored after SwiftUI has laid out the new block tree.
    @State private var scrollAnchorID: String?
    @FocusState private var isSearchFieldFocused: Bool

    private var reportBlocks: [PickyReportBlockPresentation] {
        PickyReportBlockPresentation.blocks(from: model.markdown)
    }

    private var outlineEntries: [PickyReportOutlineEntry] {
        PickyReportOutlineEntry.entries(from: reportBlocks)
    }

    var body: some View {
        let blocks = reportBlocks
        let outline = PickyReportOutlineEntry.entries(from: blocks)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                header(outline: outline)
                if isSearchPresented {
                    searchBar(blocks: blocks)
                }
                Divider().overlay(DS.Colors.borderSubtle)
                reportBody(blocks: blocks, outline: outline, proxy: proxy)
            }
            .onPreferenceChange(PickyReportBlockPositionPreferenceKey.self) { positions in
                updateScrollTracking(with: positions)
            }
            .onChange(of: model.revision) { _, _ in
                resetCopyFeedback()
                searchState.update(query: searchState.query, in: reportBlocks)
                restoreScrollPosition(using: proxy)
            }
            .onChange(of: searchState.currentMatchID) { _, matchID in
                guard let matchID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(matchID, anchor: .center)
                }
            }
        }
        .onExitCommand {
            if isSearchPresented {
                closeSearch()
            } else if outlineIsVisible {
                model.dismissOutline()
            }
        }
        .background(PickyAppearancePanelChrome.overlayBackground)
        .background(keyboardShortcuts)
        .background(viewerWidthReader)
    }

    /// Hidden buttons keep native key-equivalent routing in the panel responder
    /// chain without reserving toolbar space.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Zoom") { model.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
            Button(L10n.t("hud.report.search"), action: openSearch)
                .keyboardShortcut("f", modifiers: .command)
            if outlineEntries.count >= 3 {
                Button(L10n.t("hud.report.outline.toggle")) {
                    model.toggleOutline()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func reportContent(blocks: [PickyReportBlockPresentation]) -> some View {
        if model.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyState("No content captured for this report.")
        } else {
            PickyMarkdownReportView(
                blocks: blocks,
                fontScale: model.fontScale,
                matchingBlockIDs: Set(searchState.matches),
                currentMatchID: searchState.currentMatchID
            )
        }
    }

    private var outlinePresentationMode: PickyReportOutlinePresentationMode {
        PickyReportOutlineLayoutPolicy.presentationMode(forViewerWidth: viewerWidth)
    }

    private var outlineIsVisible: Bool {
        model.isOutlinePresented && outlineEntries.count >= 3
    }

    @ViewBuilder
    private func reportBody(
        blocks: [PickyReportBlockPresentation],
        outline: [PickyReportOutlineEntry],
        proxy: ScrollViewProxy
    ) -> some View {
        if outlineIsVisible, outlinePresentationMode == .pushed {
            HStack(spacing: 0) {
                outlineSidebar(entries: outline, proxy: proxy)
                Divider().overlay(DS.Colors.borderSubtle)
                reportScroll(blocks: blocks)
            }
        } else {
            ZStack(alignment: .topLeading) {
                reportScroll(blocks: blocks)
                if outlineIsVisible {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { model.dismissOutline() }
                        .accessibilityHidden(true)
                    outlineOverlay(entries: outline, proxy: proxy)
                }
            }
        }
    }

    private func reportScroll(blocks: [PickyReportBlockPresentation]) -> some View {
        ScrollView {
            reportContent(blocks: blocks)
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 28, trailing: 24))
        }
        .coordinateSpace(name: PickyReportScrollCoordinateSpace.name)
    }

    private func outlineOverlay(entries: [PickyReportOutlineEntry], proxy: ScrollViewProxy) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
        return outlineSidebar(entries: entries, proxy: proxy)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(PickyHUDMaterialFill(shape: shape, fallback: DS.Colors.surface1))
            .overlay(shape.stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 0.8))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 8)
    }

    private var viewerWidthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { updateViewerWidth(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in
                    updateViewerWidth(width)
                }
        }
    }

    private func updateViewerWidth(_ width: CGFloat) {
        let roundedWidth = width.rounded()
        guard viewerWidth != roundedWidth else { return }
        viewerWidth = roundedWidth
    }

    private func header(outline: [PickyReportOutlineEntry]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .pickyFont(size: 18, weight: .semibold)
                .foregroundStyle(DS.Colors.accentText)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .pickyFont(size: 15, weight: .semibold, design: .rounded)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Button(action: openReportFile) {
                    Text(model.fileURL.lastPathComponent)
                        .pickyFont(size: 11.5, weight: .regular, design: .monospaced)
                        .foregroundStyle(DS.Colors.textTertiary)
                        .underline()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open \(model.fileURL.path) in Finder")
            }
            Spacer()
            if outline.count >= 3 {
                Button { model.toggleOutline() } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.t("hud.report.outline.help"))
                .accessibilityLabel(L10n.t("hud.report.outline.toggle"))
            }
            Button(action: openSearch) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.t("hud.report.search.help"))
            .accessibilityLabel(L10n.t("hud.report.search"))
            Button(action: copyMarkdownToPasteboard) {
                Label(
                    didCopyMarkdown ? "Copied" : "Copy",
                    systemImage: didCopyMarkdown ? "checkmark" : "doc.on.doc"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.markdown.isEmpty)
            .help("Copy this report's markdown to the clipboard")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func searchBar(blocks: [PickyReportBlockPresentation]) -> some View {
        HStack(spacing: 8) {
            TextField(L10n.t("hud.report.search.placeholder"), text: Binding(
                get: { searchState.query },
                set: { searchState.update(query: $0, in: blocks) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(PickyHUDTypography.supporting)
            .focused($isSearchFieldFocused)
            .accessibilityLabel(L10n.t("hud.report.search.field.accessibilityLabel"))
            .onKeyPress { press in
                guard press.key == .return else { return .ignored }
                if press.modifiers.contains(.shift) {
                    searchState.selectPrevious()
                } else {
                    searchState.selectNext()
                }
                return .handled
            }

            Text(L10n.t(
                "hud.report.search.matchCount",
                Int64((searchState.currentIndex ?? -1) + 1),
                Int64(searchState.matches.count)
            ))
            .font(PickyHUDTypography.status)
            .foregroundStyle(DS.Colors.textSecondary)
            .monospacedDigit()
            .frame(minWidth: 42, alignment: .trailing)

            Button { searchState.selectPrevious() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(searchState.matches.isEmpty)
            .help(L10n.t("hud.report.search.previous"))
            .accessibilityLabel(L10n.t("hud.report.search.previous"))

            Button { searchState.selectNext() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(searchState.matches.isEmpty)
            .help(L10n.t("hud.report.search.next"))
            .accessibilityLabel(L10n.t("hud.report.search.next"))

            Button(action: closeSearch) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("hud.report.search.close"))
            .accessibilityLabel(L10n.t("hud.report.search.close"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(DS.Colors.surface1)
    }

    private func outlineSidebar(entries: [PickyReportOutlineEntry], proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    Button {
                        activeSectionID = entry.id
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(entry.id, anchor: .top)
                        }
                        if outlinePresentationMode == .overlay {
                            model.dismissOutline()
                        }
                    } label: {
                        Text(entry.title)
                            .font(PickyHUDTypography.supporting)
                            .foregroundStyle(activeSectionID == entry.id ? DS.Colors.accentText : DS.Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, CGFloat(entry.level - 1) * DS.Spacing.xs)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(activeSectionID == entry.id ? DS.Colors.accentSubtle : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.title)
                }
            }
            .padding(8)
        }
        .frame(width: PickyReportOutlineLayoutPolicy.sidebarWidth)
        .accessibilityLabel(L10n.t("hud.report.outline"))
    }

    private func updateScrollTracking(with positions: [PickyReportBlockPosition]) {
        guard !positions.isEmpty else { return }
        let viewportTop: CGFloat = 0
        let nearest = positions.min { abs($0.minY - viewportTop) < abs($1.minY - viewportTop) }
        if scrollAnchorID != nearest?.id {
            scrollAnchorID = nearest?.id
        }

        let headings = positions.filter(\.isHeading)
        let current = headings
            .filter { $0.minY <= 16 }
            .max { $0.minY < $1.minY }
            ?? headings.min { $0.minY < $1.minY }
        // Preference values update while scrolling, but state changes only when
        // the active heading actually changes, keeping tracking inexpensive.
        if activeSectionID != current?.id {
            activeSectionID = current?.id
        }
    }

    private func openSearch() {
        isSearchPresented = true
        searchState.update(query: searchState.query, in: reportBlocks)
        Task { @MainActor in
            await Task.yield()
            isSearchFieldFocused = true
        }
    }

    private func closeSearch() {
        isSearchPresented = false
        isSearchFieldFocused = false
        searchState.update(query: "", in: reportBlocks)
    }

    private func restoreScrollPosition(using proxy: ScrollViewProxy) {
        guard let scrollAnchorID else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(scrollAnchorID, anchor: .top)
        }
    }

    private func openReportFile() {
        NSWorkspace.shared.open(model.fileURL)
    }

    private func copyMarkdownToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.markdown, forType: .string)
        copyFeedbackTask?.cancel()
        didCopyMarkdown = true
        copyFeedbackTask = Task { @MainActor [weak model] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, model != nil else { return }
            didCopyMarkdown = false
        }
    }

    private func resetCopyFeedback() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        didCopyMarkdown = false
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .pickyFont(size: 13.5, weight: .regular, design: .default)
            .foregroundStyle(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
    }
}

final class PickyReportPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePickyCloseWindowShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if handlePickyCloseWindowShortcut(event) { return }
        super.sendEvent(event)
    }
}

final class PickyReportPanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void
    private var didClose = false

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        MainActor.assumeIsolated {
            onClose()
        }
    }
}
