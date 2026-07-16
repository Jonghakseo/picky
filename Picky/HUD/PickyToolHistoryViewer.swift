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
    private var fontScaleStore = PickyAppFontScaleStore()
    /// Shared settings store used to persist the tool history panel frame.
    /// Falls back to the default settings location for tests and previews.
    private var settingsStore = PickySettingsStore()

    private init() {}

    func configure(
        appearanceStore: PickyAppearanceStore,
        fontScaleStore: PickyAppFontScaleStore,
        settingsStore: PickySettingsStore = PickySettingsStore()
    ) {
        self.appearanceStore = appearanceStore
        self.fontScaleStore = fontScaleStore
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

        let rootView = PickyAppFontScaleRoot(store: fontScaleStore) {
            PickyToolHistoryViewerWindowView(model: model)
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
    @State private var selectedCategories: Set<PickyToolHistoryCategory> = []
    @State private var failuresOnly = false
    @State private var query = ""
    @FocusState private var isSearchFieldFocused: Bool

    private var filterResult: PickyToolHistoryFilterResult {
        PickyToolHistoryFilterPolicy.result(
            entries: model.entries,
            selectedCategories: selectedCategories,
            failuresOnly: failuresOnly,
            query: query
        )
    }

    private var hasActiveFilters: Bool {
        !selectedCategories.isEmpty || failuresOnly || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let result = filterResult
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DS.Colors.borderSubtle)
            ScrollView {
                if model.entries.isEmpty {
                    emptyState
                } else if result.entries.isEmpty {
                    filteredEmptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(result.entries) { entry in
                            PickyToolHistoryEntryView(entry: entry)
                        }
                    }
                    .padding(.top, 16)
                    filterFooter(result)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, model.entries.isEmpty || result.entries.isEmpty ? 0 : 18)
            .padding(.bottom, model.entries.isEmpty || result.entries.isEmpty ? 0 : 22)
        }
        .background(PickyAppearancePanelChrome.overlayBackground)
        .background(keyboardShortcuts)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .pickyFont(size: 16, weight: .semibold)
                .foregroundStyle(DS.Colors.accentText)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .pickyFont(size: 14, weight: .semibold, design: .rounded)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                summaryStrip
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            TextField(L10n.t("hud.toolHistory.search.placeholder"), text: $query)
                .textFieldStyle(.roundedBorder)
                .font(PickyHUDTypography.status)
                .frame(width: 150)
                .focused($isSearchFieldFocused)
                .accessibilityLabel(L10n.t("hud.toolHistory.search.accessibilityLabel"))
            scopeToggle
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .pickyFont(size: 12, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.textSecondary)
            .help("Refresh from current session state")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var keyboardShortcuts: some View {
        Button(L10n.t("hud.toolHistory.search.accessibilityLabel")) {
            isSearchFieldFocused = true
        }
        .keyboardShortcut("f", modifiers: .command)
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
                .pickyFont(size: 11, weight: isActive ? .semibold : .medium)
                .foregroundStyle(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(isActive ? DS.Colors.surface3.opacity(0.9) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var summaryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(PickyToolHistoryCategoryDisplay.ordered, id: \.category) { display in
                    let count = model.summary.count(of: display.category)
                    if count > 0 {
                        categoryFilterButton(display, count: count)
                    }
                }
                if model.summary.total > 0 {
                    failureFilterButton
                }
            }
        }
        .frame(maxWidth: 330, alignment: .leading)
    }

    private func categoryFilterButton(_ display: PickyToolHistoryCategoryDisplay, count: Int) -> some View {
        let isSelected = selectedCategories.contains(display.category)
        return Button {
            if isSelected {
                selectedCategories.remove(display.category)
            } else {
                selectedCategories.insert(display.category)
            }
        } label: {
            HStack(spacing: 3) {
                Text(display.label)
                Text("\(count)").fontWeight(.bold)
            }
            .font(PickyHUDTypography.metaMonospacedMedium)
            .foregroundStyle(isSelected ? DS.Colors.accentText : display.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(isSelected ? DS.Colors.accentSubtle : Color.clear))
            .overlay(Capsule().stroke(isSelected ? DS.Colors.accentText.opacity(0.7) : Color.clear, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("hud.toolHistory.categoryFilter.accessibilityLabel", display.label, Int64(count)))
        .accessibilityValue(isSelected ? L10n.t("hud.toolHistory.filter.selected") : "")
    }

    private var failureFilterButton: some View {
        Button { failuresOnly.toggle() } label: {
            Text(L10n.t("hud.toolHistory.failuresOnly"))
                .font(PickyHUDTypography.metaMonospacedMedium)
                .foregroundStyle(failuresOnly ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(failuresOnly ? DS.Colors.destructive.opacity(0.12) : Color.clear))
                .overlay(Capsule().stroke(failuresOnly ? DS.Colors.destructiveText.opacity(0.7) : Color.clear, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("hud.toolHistory.failuresOnly"))
        .accessibilityValue(failuresOnly ? L10n.t("hud.toolHistory.filter.selected") : "")
    }

    private func filterFooter(_ result: PickyToolHistoryFilterResult) -> some View {
        HStack {
            Text(L10n.t("hud.toolHistory.filter.resultCount", Int64(result.visibleCount), Int64(result.totalCount)))
                .font(PickyHUDTypography.status)
                .foregroundStyle(DS.Colors.textTertiary)
                .monospacedDigit()
            Spacer()
            if hasActiveFilters {
                clearFiltersButton
            }
        }
    }

    private var clearFiltersButton: some View {
        Button(action: clearFilters) {
            Text(L10n.t("hud.toolHistory.filter.clear"))
                .font(PickyHUDTypography.statusSemibold)
                .foregroundStyle(DS.Colors.accentText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("hud.toolHistory.filter.clear"))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .pickyFont(size: 24, weight: .light)
                .foregroundStyle(DS.Colors.textTertiary)
            Text("hud.toolHistory.empty")
                .pickyFont(size: 13, weight: .medium)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .pickyFont(size: 24, weight: .light)
                .foregroundStyle(DS.Colors.textTertiary)
            Text(L10n.t("hud.toolHistory.filter.empty"))
                .pickyFont(size: 13, weight: .medium)
                .foregroundStyle(DS.Colors.textSecondary)
            if hasActiveFilters {
                clearFiltersButton
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func clearFilters() {
        selectedCategories.removeAll()
        failuresOnly = false
        query = ""
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
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
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
                .pickyFont(size: 12, weight: .medium, design: .monospaced)
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
            case .succeeded: return ("● succeeded", DS.Colors.successText)
            case .failed: return ("● failed", DS.Colors.destructiveText)
            }
        }()
        return Text(text)
            .pickyFont(size: 10.5, weight: .semibold)
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
                .pickyFont(size: 10.5)
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 60, alignment: .leading)
            if let value {
                value
            } else {
                Text("(unknown)")
                    .pickyFont(size: 11)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func keyValueBlock<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .pickyFont(size: 10.5)
                .foregroundStyle(DS.Colors.textTertiary)
            content()
        }
    }

    private func monospaceLink(_ text: String) -> some View {
        Text(text)
            .pickyFont(size: 11.5, design: .monospaced)
            .foregroundStyle(DS.Colors.accentText)
            .textSelection(.enabled)
    }

    private func monospaceText(_ text: String) -> some View {
        Text(text)
            .pickyFont(size: 11, design: .monospaced)
            .foregroundStyle(DS.Colors.textSecondary)
            .textSelection(.enabled)
    }

    private func secondaryText(_ text: String) -> some View {
        Text(text)
            .pickyFont(size: 11.5)
            .foregroundStyle(DS.Colors.textSecondary)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .pickyFont(size: 11.5, design: .monospaced)
            .foregroundStyle(DS.Colors.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(DS.Colors.surface2.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small))
    }

    private func outputBlock(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(text)
                .pickyFont(size: 11, design: .monospaced)
                .foregroundStyle(DS.Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 180)
        .background(DS.Colors.surface3.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small))
    }

    private func diffBlock(_ change: PickyToolHistoryEditChange) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !change.oldText.isEmpty {
                diffLine(prefix: "-", text: change.oldText, color: DS.Colors.destructiveText, background: DS.Colors.destructive.opacity(0.08))
            }
            if !change.newText.isEmpty {
                diffLine(prefix: "+", text: change.newText, color: DS.Colors.successText, background: DS.Colors.success.opacity(0.10))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.small).stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5))
    }

    private func diffLine(prefix: String, text: String, color: Color, background: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(prefix)
                .pickyFont(size: 11, weight: .semibold, design: .monospaced)
                .foregroundStyle(color.opacity(0.7))
            Text(text)
                .pickyFont(size: 11, design: .monospaced)
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
                        .pickyFont(size: 9, weight: .semibold)
                    Text("result")
                        .pickyFont(size: 11, weight: .medium)
                    Spacer()
                    Text(isResultExpanded ? "expanded" : "collapsed · \(result.count) chars")
                        .pickyFont(size: 10.5, design: .monospaced)
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surface2.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small))
                .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.small).stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5))
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
        .init(category: .bash, label: "bash", tint: DS.Colors.warningText),
        .init(category: .edit, label: "edit", tint: DS.Colors.accentText),
        .init(category: .write, label: "write", tint: DS.Colors.floatingGradientPurple),
        .init(category: .other, label: "etc", tint: DS.Colors.textSecondary),
    ]

    static func display(for category: PickyToolHistoryCategory) -> PickyToolHistoryCategoryDisplay {
        ordered.first(where: { $0.category == category }) ?? ordered.last!
    }
}
