//
//  PickyToolHistoryViewer.swift
//  Picky
//
//  Separate window that lists all tool calls recorded for a session, mirroring
//  the structure of the Markdown report viewer.
//

import AppKit
import Combine
import SwiftUI

@MainActor
protocol PickyToolHistoryPresenting: AnyObject {
    func openHistory(sessionID: String, title: String, scope: PickyToolHistoryScope, toolsProvider: @escaping () -> [PickyToolActivity])
}

@MainActor
final class PickyToolHistoryPresenter: PickyToolHistoryPresenting {
    static let shared = PickyToolHistoryPresenter()

    private struct HistoryRecord {
        let panel: NSPanel
        let model: PickyToolHistoryViewerModel
        let delegate: PickyReportPanelDelegate
        // Held strongly so the underlying NotificationCenter observers stay
        // alive for the panel's lifetime. See PickyDetachedPanelFrameAutosaver.
        let frameAutosaver: PickyDetachedPanelFrameAutosaver
    }

    private var records: [String: HistoryRecord] = [:]
    private var appearanceStore = PickyAppearanceStore()
    /// Shared settings store used to persist the tool history panel frame.
    /// Falls back to the default settings location for tests and previews.
    private var settingsStore = PickySettingsStore()

    private init() {}

    func configure(appearanceStore: PickyAppearanceStore, settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.appearanceStore = appearanceStore
        self.settingsStore = settingsStore
    }

    func openHistory(sessionID: String, title: String, scope: PickyToolHistoryScope, toolsProvider: @escaping () -> [PickyToolActivity]) {
        if let existing = records[sessionID] {
            existing.model.refresh = toolsProvider
            existing.model.update(title: title, tools: toolsProvider(), scope: scope)
            existing.panel.title = "Tool history — \(title)"
            NSApp.activate(ignoringOtherApps: true)
            existing.panel.orderFrontRegardless()
            existing.panel.makeKey()
            return
        }

        let model = PickyToolHistoryViewerModel(title: title, tools: toolsProvider(), scope: scope, refresh: toolsProvider)
        let panel = PickyReportPanel(
            contentRect: targetFrame(),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Tool history — \(title)"
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = PickyAppearancePanelChrome.windowBackground()
        panel.minSize = NSSize(width: 620, height: 420)
        // Persist the last user-moved frame through PickySettingsStore so the
        // window reopens at the same spot even when several tool history
        // panels (or report panels) coexist; see PickyDetachedPanelFrameAutosaver.
        let frameAutosaver = PickyDetachedPanelFrameAutosaver(
            panel: panel,
            persister: PickyDetachedPanelFramePersister.backed(by: settingsStore, kind: .toolHistoryViewer)
        )

        let rootView = PickyToolHistoryViewerWindowView(model: model)
            .environmentObject(appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { rootView })
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        let delegate = PickyReportPanelDelegate { [weak self, weak panel] in
            if let panel { self?.remove(panel: panel) }
        }
        panel.delegate = delegate
        records[sessionID] = HistoryRecord(panel: panel, model: model, delegate: delegate, frameAutosaver: frameAutosaver)
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
        let width = min(CGFloat(900), visibleFrame.width - 48)
        let height = min(CGFloat(720), visibleFrame.height - 48)
        return NSRect(
            x: visibleFrame.maxX - width - 24,
            y: visibleFrame.maxY - height - 24,
            width: width,
            height: height
        )
    }
}

@MainActor
final class PickyToolHistoryViewerModel: ObservableObject {
    @Published private(set) var title: String
    @Published private(set) var tools: [PickyToolActivity]
    @Published private(set) var scope: PickyToolHistoryScope
    @Published private(set) var entries: [PickyToolHistoryEntry]
    @Published private(set) var summary: PickyToolHistorySummary
    let initialScope: PickyToolHistoryScope
    var refresh: () -> [PickyToolActivity]

    init(title: String, tools: [PickyToolActivity], scope: PickyToolHistoryScope, refresh: @escaping () -> [PickyToolActivity]) {
        self.title = title
        self.tools = tools
        self.scope = scope
        self.initialScope = scope
        let entries = PickyToolHistoryRenderer.entries(from: tools, scope: scope)
        self.entries = entries
        self.summary = PickyToolHistorySummary(entries: entries)
        self.refresh = refresh
    }

    func update(title: String, tools: [PickyToolActivity], scope: PickyToolHistoryScope? = nil) {
        self.title = title
        self.tools = tools
        if let scope { self.scope = scope }
        recompute()
    }

    func setScope(_ newScope: PickyToolHistoryScope) {
        scope = newScope
        recompute()
    }

    func reload() {
        update(title: title, tools: refresh())
    }

    private func recompute() {
        let entries = PickyToolHistoryRenderer.entries(from: tools, scope: scope)
        self.entries = entries
        self.summary = PickyToolHistorySummary(entries: entries)
    }
}

struct PickyToolHistoryViewerWindowView: View {
    @ObservedObject var model: PickyToolHistoryViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DS.Colors.borderSubtle)
            ScrollView {
                if model.entries.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.entries) { entry in
                            PickyToolHistoryEntryView(entry: entry)
                        }
                    }
                    .padding(EdgeInsets(top: 16, leading: 18, bottom: 22, trailing: 18))
                }
            }
        }
        .background(PickyAppearancePanelChrome.overlayBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.Colors.accentText)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                summaryStrip
            }
            Spacer()
            scopeToggle
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.textSecondary)
            .help("Refresh from current session state")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var scopeToggle: some View {
        if model.initialScope.isWholeSession {
            EmptyView()
        } else {
            HStack(spacing: 0) {
                scopeButton(label: "This turn", isActive: !model.scope.isWholeSession) {
                    model.setScope(model.initialScope)
                }
                scopeButton(label: "Whole session", isActive: model.scope.isWholeSession) {
                    model.setScope(.session)
                }
            }
            .background(Capsule().fill(DS.Colors.surface2.opacity(0.5)))
            .overlay(Capsule().stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5))
            .clipShape(Capsule())
        }
    }

    private func scopeButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(isActive ? DS.Colors.surface3.opacity(0.9) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var summaryStrip: some View {
        HStack(spacing: 10) {
            ForEach(PickyToolHistoryCategoryDisplay.ordered, id: \.category) { display in
                let count = model.summary.count(of: display.category)
                if count > 0 {
                    HStack(spacing: 3) {
                        Text(display.label)
                        Text("\(count)").fontWeight(.bold)
                    }
                    .font(PickyHUDTypography.metaMonospacedMedium)
                    .foregroundStyle(display.tint)
                }
            }
            if model.summary.total > 0 {
                Text("· total \(model.summary.total)")
                    .font(PickyHUDTypography.metaMonospacedMedium)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DS.Colors.textTertiary)
            Text("hud.toolHistory.empty")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

struct PickyToolHistoryEntryView: View {
    let entry: PickyToolHistoryEntry
    @State private var isResultExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Divider().overlay(DS.Colors.borderSubtle.opacity(0.6))
            body(for: entry.detail)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(DS.Colors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { isResultExpanded = entry.status == .failed && entry.category == .other }
    }

    private var head: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", entry.index))
                .font(PickyHUDTypography.metaMonospacedMedium)
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(minWidth: 22, alignment: .leading)
            categoryChip
            Text(entry.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let durationMs = entry.durationMs {
                Text(formatDuration(durationMs))
                    .font(PickyHUDTypography.metaMonospacedMedium)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            statusLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Colors.surface2.opacity(0.6))
    }

    private var categoryChip: some View {
        let display = PickyToolHistoryCategoryDisplay.display(for: entry.category)
        return Text(display.label)
            .font(PickyHUDTypography.metaMonospacedSemibold)
            .foregroundStyle(display.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(display.tint.opacity(0.14)))
    }

    private var statusLabel: some View {
        let (text, color): (String, Color) = {
            switch entry.status {
            case .running: return ("● running", DS.Colors.accentText)
            case .succeeded: return ("● succeeded", DS.Colors.success)
            case .failed: return ("● failed", DS.Colors.destructiveText)
            }
        }()
        return Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func body(for detail: PickyToolHistoryDetail) -> some View {
        switch detail {
        case let .read(file, range, summary):
            keyValueRow("file", value: file.map { AnyView(monospaceLink($0)) })
            keyValueRow("range", value: range.map { AnyView(monospaceText($0)) })
            keyValueRow("result", value: summary.map { AnyView(secondaryText($0)) })
        case let .bash(command, output):
            if let command {
                keyValueBlock("$") { codeBlock(command) }
            } else {
                keyValueRow("$", value: AnyView(secondaryText("(command not captured)")))
            }
            if let output {
                keyValueBlock("output") { outputBlock(output) }
            }
        case let .edit(file, changes):
            keyValueRow("file", value: file.map { AnyView(monospaceLink($0)) })
            keyValueRow("edits", value: AnyView(secondaryText("\(changes.count) change\(changes.count == 1 ? "" : "s")")))
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                diffBlock(change)
            }
        case let .write(file, content):
            keyValueRow("file", value: file.map { AnyView(monospaceLink($0)) })
            if let content {
                keyValueBlock("content") { codeBlock(content) }
            }
        case let .generic(argsJSON, result):
            if let argsJSON {
                keyValueBlock("arguments") { codeBlock(argsJSON) }
            } else {
                keyValueRow("arguments", value: AnyView(secondaryText("(none)")))
            }
            if let result {
                resultDisclosure(result)
            }
        }
    }

    private func keyValueRow(_ key: String, value: AnyView?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 10.5))
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 60, alignment: .leading)
            if let value {
                value
            } else {
                Text("(unknown)")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func keyValueBlock<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .font(.system(size: 10.5))
                .foregroundStyle(DS.Colors.textTertiary)
            content()
        }
    }

    private func monospaceLink(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(DS.Colors.accentText)
            .textSelection(.enabled)
    }

    private func monospaceText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(DS.Colors.textSecondary)
            .textSelection(.enabled)
    }

    private func secondaryText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(DS.Colors.textSecondary)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(DS.Colors.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(DS.Colors.surface2.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func outputBlock(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 180)
        .background(DS.Colors.surface3.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func diffBlock(_ change: PickyToolHistoryEditChange) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !change.oldText.isEmpty {
                diffLine(prefix: "-", text: change.oldText, color: DS.Colors.destructiveText, background: DS.Colors.destructive.opacity(0.08))
            }
            if !change.newText.isEmpty {
                diffLine(prefix: "+", text: change.newText, color: DS.Colors.success, background: DS.Colors.success.opacity(0.10))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5))
    }

    private func diffLine(prefix: String, text: String, color: Color, background: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(prefix)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color.opacity(0.7))
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(background)
    }

    private func resultDisclosure(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isResultExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isResultExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("result")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(isResultExpanded ? "expanded" : "collapsed · \(result.count) chars")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surface2.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            if isResultExpanded {
                outputBlock(result)
            }
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms >= 60_000 {
            let seconds = Double(ms) / 1000
            return String(format: "%.1fm", seconds / 60)
        }
        if ms >= 1_000 {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        return "\(ms)ms"
    }
}

private struct PickyToolHistoryCategoryDisplay {
    let category: PickyToolHistoryCategory
    let label: String
    let tint: Color

    static let ordered: [PickyToolHistoryCategoryDisplay] = [
        .init(category: .read, label: "read", tint: DS.Colors.info),
        .init(category: .bash, label: "bash", tint: DS.Colors.warning),
        .init(category: .edit, label: "edit", tint: DS.Colors.accentText),
        .init(category: .write, label: "write", tint: DS.Colors.floatingGradientPurple),
        .init(category: .other, label: "etc", tint: DS.Colors.textSecondary),
    ]

    static func display(for category: PickyToolHistoryCategory) -> PickyToolHistoryCategoryDisplay {
        ordered.first(where: { $0.category == category }) ?? ordered.last!
    }
}
