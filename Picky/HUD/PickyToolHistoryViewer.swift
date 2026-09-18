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

/// Resolves paths recorded by file tools without consulting the file system.
/// Relative paths resolve only against an explicit session working directory.
enum PickyToolHistoryFilePathPolicy {
    static func urlToOpen(for path: String, workingDirectory: String? = nil) -> URL? {
        guard !path.isEmpty else { return nil }
        let expandedPath = (path as NSString).expandingTildeInPath
        if (expandedPath as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expandedPath)
        }
        guard !expandedPath.hasPrefix("~"), let workingDirectory else { return nil }
        let base = (workingDirectory as NSString).expandingTildeInPath
        guard (base as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(expandedPath).standardizedFileURL
    }
}

@MainActor
protocol PickyToolHistoryPresenting: AnyObject {
    func openHistory(
        sessionID: String, title: String, scope: PickyToolHistoryScope,
        snapshotProvider: @escaping () -> PickyToolHistorySnapshot,
        updates: AnyPublisher<PickyToolHistorySnapshot, Never>,
        detailLoader: @escaping PickyToolHistoryDetailLoader
    )
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

    func openHistory(
        sessionID: String, title: String, scope: PickyToolHistoryScope,
        snapshotProvider: @escaping () -> PickyToolHistorySnapshot,
        updates: AnyPublisher<PickyToolHistorySnapshot, Never>,
        detailLoader: @escaping PickyToolHistoryDetailLoader
    ) {
        if let existing = records[sessionID] {
            existing.model.refresh = snapshotProvider
            existing.model.update(title: title, snapshot: snapshotProvider(), scope: scope)
            existing.model.connect(updates: updates)
            existing.panel.title = "Tool history — \(title)"
            NSApp.activate(ignoringOtherApps: true)
            existing.panel.orderFrontRegardless()
            existing.panel.makeKey()
            return
        }

        let model = PickyToolHistoryViewerModel(title: title, snapshot: snapshotProvider(), scope: scope,
                                              refresh: snapshotProvider, detailLoader: detailLoader)
        model.connect(updates: updates)
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
        records.values.first(where: { $0.panel === panel })?.model.closeDetails()
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
    @Published private(set) var workingDirectory: String?
    @Published private(set) var scope: PickyToolHistoryScope
    @Published private(set) var entries: [PickyToolHistoryEntry]
    @Published private(set) var summary: PickyToolHistorySummary
    let initialScope: PickyToolHistoryScope
    var refresh: () -> PickyToolHistorySnapshot
    private var sessionFilePath: String?
    private var inlineDetails: [String: PickyToolHistoryDetailModel] = [:]
    private var argumentDetails: [String: PickyToolHistoryDetailModel] = [:]
    private let detailLoader: PickyToolHistoryDetailLoader
    private var updatesSubscription: AnyCancellable?

    init(title: String, snapshot: PickyToolHistorySnapshot, scope: PickyToolHistoryScope,
         refresh: @escaping () -> PickyToolHistorySnapshot, detailLoader: @escaping PickyToolHistoryDetailLoader) {
        self.title = title
        self.tools = snapshot.tools
        self.workingDirectory = snapshot.workingDirectory
        self.sessionFilePath = snapshot.sessionFilePath
        self.scope = scope
        self.initialScope = scope
        let entries = PickyToolHistoryRenderer.entries(from: snapshot.tools, scope: scope)
        self.entries = entries
        self.summary = PickyToolHistorySummary(entries: entries)
        self.refresh = refresh
        self.detailLoader = detailLoader
    }

    func connect(updates: AnyPublisher<PickyToolHistorySnapshot, Never>) {
        updatesSubscription = updates.removeDuplicates().sink { [weak self] snapshot in
            guard let self else { return }
            self.update(title: self.title, snapshot: snapshot)
        }
    }

    func update(title: String, snapshot: PickyToolHistorySnapshot, scope: PickyToolHistoryScope? = nil) {
        for (id, detail) in inlineDetails where sessionFilePath != snapshot.sessionFilePath
            || !snapshot.tools.contains(where: { $0.toolCallId == id }) {
            detail.invalidateSource()
            inlineDetails.removeValue(forKey: id)
        }
        for (id, detail) in argumentDetails where sessionFilePath != snapshot.sessionFilePath
            || !snapshot.tools.contains(where: { $0.toolCallId == id }) {
            detail.invalidateSource()
            argumentDetails.removeValue(forKey: id)
        }
        self.title = title
        self.tools = snapshot.tools
        self.workingDirectory = snapshot.workingDirectory
        self.sessionFilePath = snapshot.sessionFilePath
        if let scope { self.scope = scope }
        recompute()
    }

    func inlineDetail(toolCallID: String) -> PickyToolHistoryDetailModel? {
        if let existing = inlineDetails[toolCallID] { return existing }
        guard let tool = tools.first(where: { $0.toolCallId == toolCallID }) else { return nil }
        let model = makeDetail(tool: tool, loadsAllPages: true)
        inlineDetails[toolCallID] = model
        return model
    }

    func inlineArguments(toolCallID: String) -> PickyToolHistoryDetailModel? {
        if let existing = argumentDetails[toolCallID] { return existing }
        guard let tool = tools.first(where: { $0.toolCallId == toolCallID }) else { return nil }
        let model = makeDetail(tool: tool, loadsAllPages: true)
        argumentDetails[toolCallID] = model
        return model
    }

    private func makeDetail(tool: PickyToolActivity, loadsAllPages: Bool) -> PickyToolHistoryDetailModel {
        let toolCallID = tool.toolCallId
        let expectedFile = sessionFilePath
        let loader = detailLoader
        return PickyToolHistoryDetailModel(toolName: tool.name, loadsAllPages: loadsAllPages) { part, cursor in
            guard let expectedFile else {
                return PickyToolHistoryDetailResult(
                    sessionId: "", requestId: "", toolCallId: toolCallID, expectedSessionFile: "",
                    part: part, status: .unavailable, text: nil, nextCursor: nil,
                    reason: "missingSessionFile", attachmentsOmitted: nil
                )
            }
            return try await loader(toolCallID, expectedFile, part, cursor)
        }
    }

    func closeDetails() {
        inlineDetails.values.forEach { $0.cancel() }
        inlineDetails.removeAll()
        argumentDetails.values.forEach { $0.cancel() }
        argumentDetails.removeAll()
    }

    func setScope(_ newScope: PickyToolHistoryScope) {
        scope = newScope
        recompute()
    }

    func reload() {
        update(title: title, snapshot: refresh())
    }

    private func recompute() {
        let entries = PickyToolHistoryRenderer.entries(from: tools, scope: scope)
        self.entries = entries
        self.summary = PickyToolHistorySummary(entries: entries)
    }
}
