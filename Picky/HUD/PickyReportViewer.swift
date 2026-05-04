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
        case codeBlock(String)
    }

    func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false

        func flushParagraph() {
            let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraphLines.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
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
                continue
            }

            if inCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = parseHeading(line) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                continue
            }

            paragraphLines.append(rawLine)
        }

        if inCodeBlock {
            blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    func inlineAttributedString(for markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            return attributed
        }
        return AttributedString(markdown)
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
}

struct PickyReportDocument: Equatable {
    let answerMarkdown: String
    let metadataMarkdown: String

    init(markdown: String) {
        let lines = markdown.components(separatedBy: .newlines)
        guard let answerHeadingIndex = lines.firstIndex(where: { normalizedHeading($0) == "final answer" }) else {
            answerMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            metadataMarkdown = ""
            return
        }

        let metadataStartIndex = lines[(answerHeadingIndex + 1)...].firstIndex { line in
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") else { return false }
            return Self.metadataHeadingTitles.contains(normalizedHeading(line))
        } ?? lines.endIndex

        answerMarkdown = lines[(answerHeadingIndex + 1)..<metadataStartIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let leadingMetadata = lines[..<answerHeadingIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingMetadata = metadataStartIndex < lines.endIndex
            ? lines[metadataStartIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        metadataMarkdown = [leadingMetadata, trailingMetadata]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var hasMetadata: Bool {
        !metadataMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let metadataHeadingTitles = Set(["tool summary", "changed files", "pull requests", "artifacts"])
}

private func normalizedHeading(_ line: String) -> String {
    line.trimmingCharacters(in: .whitespacesAndNewlines)
        .drop(while: { $0 == "#" })
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private enum PickyReportTab: String, CaseIterable, Identifiable {
    case answer
    case metadata

    var id: String { rawValue }

    var label: String {
        switch self {
        case .answer: "Answer"
        case .metadata: "Metadata"
        }
    }
}

struct PickyMarkdownReportView: View {
    let markdown: String
    /// Multiplier applied to every font size in this view. 1.0 maps to the report's
    /// readable defaults; ⌘+ / ⌘- on the report panel update the model and re-render
    /// this view at the new scale.
    var fontScale: Double = 1.0
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
        case .paragraph(let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(.system(size: scaled(Self.bodyBaseSize), weight: .regular, design: .default))
                .foregroundStyle(DS.Colors.textPrimary.opacity(0.92))
                .lineSpacing(3)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: scaled(Self.bodyBaseSize), weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(renderer.inlineAttributedString(for: text))
                    .font(.system(size: scaled(Self.bodyBaseSize), weight: .regular, design: .default))
                    .foregroundStyle(DS.Colors.textPrimary.opacity(0.92))
                    .lineSpacing(3)
            }
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

    private func font(forHeadingLevel level: Int) -> Font {
        switch level {
        case 1: .system(size: scaled(26), weight: .semibold, design: .rounded)
        case 2: .system(size: scaled(20), weight: .semibold, design: .rounded)
        case 3: .system(size: scaled(17), weight: .semibold, design: .rounded)
        default: .system(size: scaled(15.5), weight: .semibold, design: .rounded)
        }
    }

    private func scaled(_ size: CGFloat) -> CGFloat {
        size * CGFloat(fontScale)
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
    }

    private var records: [String: ReportRecord] = [:]
    /// Held by the presenter for the lifetime of the app once `configure(appearanceStore:)`
    /// runs from `CompanionAppDelegate`. The fallback default keeps unit tests and
    /// previews working without crashing if `configure` was never called.
    private var appearanceStore = PickyAppearanceStore()
    /// Shared settings store used to load/persist the markdown report zoom level.
    /// Falls back to the default settings location for tests and previews.
    private var settingsStore = PickySettingsStore()

    private init() {}

    /// Wires the live appearance store so the report panel flips with the rest of
    /// the app. Called once from `CompanionAppDelegate` at startup.
    func configure(appearanceStore: PickyAppearanceStore, settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.appearanceStore = appearanceStore
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
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = PickyAppearancePanelChrome.windowBackground()
        panel.minSize = NSSize(width: 620, height: 420)

        let rootView = PickyReportViewerWindowView(model: model)
            .environmentObject(appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        let delegate = PickyReportPanelDelegate { [weak self, weak panel] in
            if let panel { self?.remove(panel: panel) }
        }
        panel.delegate = delegate
        records[sessionID] = ReportRecord(panel: panel, model: model, delegate: delegate)
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
    @Published private(set) var document: PickyReportDocument
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
        self.document = PickyReportDocument(markdown: markdown)
        self.fontScalePersister = fontScalePersister
        self.fontScale = PickyFontScales.clamped(fontScalePersister?.load() ?? PickyFontScales.defaults.markdownReport)
    }

    func update(title: String, fileURL: URL, markdown: String) {
        self.title = title
        self.fileURL = fileURL
        self.markdown = markdown
        self.document = PickyReportDocument(markdown: markdown)
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
    @State private var selectedTab: PickyReportTab = .answer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DS.Colors.borderSubtle)
            ScrollView {
                reportContent
                    .padding(EdgeInsets(top: 22, leading: 24, bottom: 28, trailing: 24))
            }
        }
        .onChange(of: model.revision) { _, _ in selectedTab = .answer }
        .background(DS.Colors.background)
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
        switch selectedTab {
        case .answer:
            if model.document.answerMarkdown.isEmpty {
                emptyState("No final answer captured for this report.")
            } else {
                PickyMarkdownReportView(markdown: model.document.answerMarkdown, fontScale: model.fontScale)
            }
        case .metadata:
            if model.document.metadataMarkdown.isEmpty {
                emptyState("No metadata is available for this report.")
            } else {
                PickyMarkdownReportView(markdown: model.document.metadataMarkdown, fontScale: model.fontScale)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Colors.accentText)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(model.fileURL.lastPathComponent)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Picker("Report section", selection: $selectedTab) {
                ForEach(PickyReportTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5, weight: .regular, design: .default))
            .foregroundStyle(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
    }
}

final class PickyReportPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
