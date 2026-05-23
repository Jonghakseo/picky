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
        let computed = computeBlocks(from: markdown)
        Self.blockCache.setObject(BlockCacheEntry(blocks: computed), forKey: key, cost: markdown.utf8.count)
        return computed
    }

    private func computeBlocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false
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
            if line.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCodeBlock = false
                } else {
                    flushParagraph()
                    inCodeBlock = true
                }
                index += 1
                continue
            }

            if inCodeBlock {
                codeLines.append(rawLine)
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

        if inCodeBlock {
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

    private final class BlockCacheEntry {
        let blocks: [Block]
        init(blocks: [Block]) { self.blocks = blocks }
    }

    private final class InlineCacheEntry {
        let value: AttributedString
        init(value: AttributedString) { self.value = value }
    }
}

struct PickyMarkdownReportView: View {
    let markdown: String
    /// Multiplier applied to every font size in this view. 1.0 maps to the report's
    /// readable defaults; ⌘+ / ⌘- on the report panel update the model and re-render
    /// this view at the new scale.
    var fontScale: Double = 1.0
    /// Global app font scale (⌘+ / ⌘- when no detached panel has focus). Composed
    /// multiplicatively with the per-panel `fontScale` so a user who set the app
    /// to 110% and the panel to 130% sees 143% on the report body. Declared as an
    /// `@Environment` value so the view re-renders the moment the root container
    /// publishes a new app scale.
    @Environment(\.pickyAppFontScale) private var appFontScale
    private let renderer = PickyReportMarkdownRenderer()

    /// Body copy size at scale 1.0. Bumped from the original 13.5pt because users
    /// reported the dense report column was hard to read at default macOS Retina
    /// scaling. Heading sizes derive from this so the type ladder stays balanced.
    private static let bodyBaseSize: CGFloat = 15
    private static let codeBaseSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(renderer.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
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
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let widths = tableColumnWidths(columnCount: headers.count, firstHeader: headers.first ?? "")
        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, widths: widths, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, widths: widths, isHeader: false)
                }
            }
            .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func tableColumnWidths(columnCount: Int, firstHeader: String) -> [CGFloat] {
        let firstIsIndex = isIndexColumnHeader(firstHeader)
        return (0..<columnCount).map {
            tableColumnWidth(index: $0, columnCount: columnCount, firstIsIndex: firstIsIndex)
        }
    }

    private func isIndexColumnHeader(_ header: String) -> Bool {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return true }
        return ["#", "no", "no.", "번호", "순번", "idx", "index"].contains(trimmed)
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

    private func tableColumnWidth(index: Int, columnCount: Int, firstIsIndex: Bool) -> CGFloat {
        if index == 0 && columnCount > 2 && firstIsIndex { return scaled(52) }
        if columnCount >= 5 {
            if index == 1 { return scaled(120) }
            if index == columnCount - 1 { return scaled(300) }
            return scaled(340)
        }
        if columnCount == 4 { return scaled(260) }
        return scaled(220)
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
            fontScalePersister: makeFontScalePersister()
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

    private let fontScalePersister: PickyMarkdownReportFontScalePersister?

    init(
        title: String,
        fileURL: URL,
        markdown: String,
        fontScalePersister: PickyMarkdownReportFontScalePersister? = nil
    ) {
        self.title = title
        self.fileURL = fileURL
        self.markdown = markdown
        self.fontScalePersister = fontScalePersister
        self.fontScale = PickyFontScales.clamped(fontScalePersister?.load() ?? PickyFontScales.defaults.markdownReport)
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

    private func setFontScale(_ newValue: Double) {
        let clamped = PickyFontScales.clamped(newValue)
        guard clamped != fontScale else { return }
        fontScale = clamped
        fontScalePersister?.save(clamped)
    }
}

struct PickyReportViewerWindowView: View {
    @ObservedObject var model: PickyReportViewerModel
    @State private var didCopyMarkdown = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DS.Colors.borderSubtle)
            ScrollView {
                reportContent
                    .padding(EdgeInsets(top: 22, leading: 24, bottom: 28, trailing: 24))
            }
        }
        .onChange(of: model.revision) { _, _ in resetCopyFeedback() }
        .background(PickyAppearancePanelChrome.overlayBackground)
        .background(zoomKeyboardShortcuts)
    }

    /// Hidden buttons that bind ⌘+ / ⌘- / ⌘0 to the model's zoom controls.
    /// Placed in a `.background(...)` of zero size so they exist in the responder chain
    /// without taking layout space or showing focus rings.
    private var zoomKeyboardShortcuts: some View {
        ZStack {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Zoom") { model.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var reportContent: some View {
        if model.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyState("No content captured for this report.")
        } else {
            PickyMarkdownReportView(markdown: model.markdown, fontScale: model.fontScale)
        }
    }

    private var header: some View {
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
