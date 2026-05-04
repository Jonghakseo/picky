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

struct PickyMarkdownReportView: View {
    let markdown: String
    private let renderer = PickyReportMarkdownRenderer()

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
                .foregroundStyle(Color.white)
                .padding(.top, level == 1 ? 2 : 8)
        case .paragraph(let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(.system(size: 13.5, weight: .regular, design: .default))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineSpacing(3)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
                Text(renderer.inlineAttributedString(for: text))
                    .font(.system(size: 13.5, weight: .regular, design: .default))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineSpacing(3)
            }
        case .codeBlock(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func font(forHeadingLevel level: Int) -> Font {
        switch level {
        case 1: .system(size: 24, weight: .semibold, design: .rounded)
        case 2: .system(size: 18, weight: .semibold, design: .rounded)
        case 3: .system(size: 16, weight: .semibold, design: .rounded)
        default: .system(size: 14.5, weight: .semibold, design: .rounded)
        }
    }
}

@MainActor
protocol PickyReportPresenting: AnyObject {
    func openReport(sessionID: String, title: String, fileURL: URL, markdown: String) throws
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

    private init() {}

    func openReport(sessionID: String, title: String, fileURL: URL, markdown: String) throws {
        if let existing = records[sessionID] {
            existing.model.update(title: title, fileURL: fileURL, markdown: markdown)
            existing.panel.title = "Picky Report — \(title)"
            NSApp.activate(ignoringOtherApps: true)
            existing.panel.orderFrontRegardless()
            existing.panel.makeKey()
            return
        }

        let model = PickyReportViewerModel(title: title, fileURL: fileURL, markdown: markdown)
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
        panel.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.98)
        panel.minSize = NSSize(width: 620, height: 420)

        let hostingView = NSHostingView(rootView: PickyReportViewerWindowView(model: model))
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

    init(title: String, fileURL: URL, markdown: String) {
        self.title = title
        self.fileURL = fileURL
        self.markdown = markdown
    }

    func update(title: String, fileURL: URL, markdown: String) {
        self.title = title
        self.fileURL = fileURL
        self.markdown = markdown
    }
}

struct PickyReportViewerWindowView: View {
    @ObservedObject var model: PickyReportViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                PickyMarkdownReportView(markdown: model.markdown)
                    .padding(EdgeInsets(top: 22, leading: 24, bottom: 28, trailing: 24))
            }
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.96), Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.cyan.opacity(0.9))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(model.fileURL.lastPathComponent)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
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
