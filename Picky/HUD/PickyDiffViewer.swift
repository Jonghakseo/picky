//
//  PickyDiffViewer.swift
//  Picky
//
//  Detached unified diff viewer for git changes surfaced from the HUD.
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
protocol PickyDiffViewerPresenting: AnyObject {
    func openDiff(sessionID: String, title: String, cwd: String, initialScope: PickyGitDiffViewerScope)
}

@MainActor
final class PickyDiffViewerPresenter: PickyDiffViewerPresenting {
    static let shared = PickyDiffViewerPresenter()

    private struct DiffRecord {
        let panel: NSPanel
        let model: PickyDiffViewerModel
        let delegate: PickyReportPanelDelegate
        let frameAutosaver: PickyDetachedPanelFrameAutosaver
    }

    private var records: [String: DiffRecord] = [:]
    private var appearanceStore = PickyAppearanceStore()
    private var settingsStore = PickySettingsStore()

    private init() {}

    func configure(appearanceStore: PickyAppearanceStore, settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.appearanceStore = appearanceStore
        self.settingsStore = settingsStore
    }

    func openDiff(sessionID: String, title: String, cwd: String, initialScope: PickyGitDiffViewerScope) {
        let key = recordKey(sessionID: sessionID, cwd: cwd)
        if let existing = records[key] {
            existing.model.update(title: title, cwd: cwd, initialScope: initialScope)
            existing.panel.title = "Git Diff — \(title)"
            NSApp.activate(ignoringOtherApps: true)
            existing.panel.orderFrontRegardless()
            existing.panel.makeKey()
            return
        }

        let model = PickyDiffViewerModel(title: title, cwd: cwd, initialScope: initialScope)
        let panel = PickyReportPanel(
            contentRect: targetFrame(),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Git Diff — \(title)"
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = PickyAppearancePanelChrome.windowBackground()
        panel.minSize = NSSize(width: 760, height: 480)

        let frameAutosaver = PickyDetachedPanelFrameAutosaver(
            panel: panel,
            persister: PickyDetachedPanelFramePersister.backed(by: settingsStore, kind: .diffViewer)
        )

        let rootView = PickyDiffViewerWindowView(model: model)
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
        records[key] = DiffRecord(panel: panel, model: model, delegate: delegate, frameAutosaver: frameAutosaver)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func remove(panel: NSPanel) {
        records = records.filter { $0.value.panel !== panel }
    }

    private func recordKey(sessionID: String, cwd: String) -> String {
        let normalizedCwd = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
        return "\(sessionID)::\(normalizedCwd)"
    }

    private func targetFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(CGFloat(1040), visibleFrame.width - 48)
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
final class PickyDiffViewerModel: ObservableObject {
    @Published private(set) var title: String
    @Published private(set) var cwd: String
    @Published private(set) var selectedScope: PickyGitDiffViewerScope
    @Published private(set) var data: PickyGitDiffViewerData?
    @Published private(set) var selectedFileID: String?
    @Published private(set) var unifiedDiff: String = ""
    @Published private(set) var isLoadingData = false
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var diffErrorMessage: String?

    private let provider: any PickyGitDiffReviewProviding
    private var diffSession: (any PickyGitDiffReviewSessioning)?
    private var diffCache: [PickyGitDiffViewerScope: [String: String]] = [:]
    private var loadGeneration = UUID()
    private var diffGeneration = UUID()

    init(title: String, cwd: String, initialScope: PickyGitDiffViewerScope, provider: any PickyGitDiffReviewProviding = PickyGitDiffReviewProvider()) {
        self.title = title
        self.cwd = cwd
        self.selectedScope = initialScope
        self.provider = provider
        Task { await reload() }
    }

    deinit {
        if let diffSession {
            Task { await diffSession.close() }
        }
    }

    var selectedScopeData: PickyGitDiffScopeData? {
        data?.scopeData(selectedScope)
    }

    var selectedFile: PickyGitDiffFile? {
        guard let selectedFileID else { return nil }
        return selectedScopeData?.files.first { $0.id == selectedFileID }
    }

    var repositoryTitle: String {
        data?.repositoryName ?? URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
    }

    var branchTitle: String {
        data?.branchName ?? "Loading branch…"
    }

    var summaryText: String {
        guard let scopeData = selectedScopeData else { return "No diff data" }
        return "\(scopeData.fileCount) files · +\(scopeData.insertions) -\(scopeData.deletions) · \(scopeData.baseLabel) → \(scopeData.targetLabel)"
    }

    func update(title: String, cwd: String, initialScope: PickyGitDiffViewerScope) {
        let cwdChanged = self.cwd != cwd
        self.title = title
        self.cwd = cwd
        if cwdChanged {
            closeDiffSession()
            invalidateInFlightDiffLoad()
            data = nil
            selectedFileID = nil
            unifiedDiff = ""
            diffCache.removeAll()
        }
        setScope(initialScope)
        if cwdChanged || data == nil {
            Task { await reload() }
        }
    }

    func reload() async {
        let generation = UUID()
        loadGeneration = generation
        invalidateInFlightDiffLoad()
        isLoadingData = true
        errorMessage = nil
        diffErrorMessage = nil
        unifiedDiff = ""
        selectedFileID = nil
        diffCache.removeAll()
        closeDiffSession()
        let session = makeDiffSession()
        diffSession = session

        do {
            let loaded = try await session.load(cwd: cwd)
            guard loadGeneration == generation else {
                await session.close()
                return
            }
            data = loaded
            isLoadingData = false
            selectFirstAvailableFile()
        } catch {
            await session.close()
            guard loadGeneration == generation else { return }
            if diffSession === session {
                diffSession = nil
            }
            data = nil
            isLoadingData = false
            errorMessage = Self.displayMessage(for: error)
        }
    }

    func refresh() {
        Task { await reload() }
    }

    func setScope(_ scope: PickyGitDiffViewerScope) {
        guard selectedScope != scope else { return }
        selectedScope = scope
        diffErrorMessage = nil
        unifiedDiff = ""
        selectFirstAvailableFile()
    }

    func selectFile(_ file: PickyGitDiffFile) {
        guard selectedFileID != file.id else { return }
        selectedFileID = file.id
        diffErrorMessage = nil
        unifiedDiff = ""
        loadSelectedDiff()
    }

    private func selectFirstAvailableFile() {
        selectedFileID = selectedScopeData?.files.first?.id
        loadSelectedDiff()
    }

    private func loadSelectedDiff() {
        let generation = invalidateInFlightDiffLoad()
        guard let fileID = selectedFileID else {
            isLoadingDiff = false
            unifiedDiff = ""
            return
        }
        if let cached = diffCache[selectedScope]?[fileID] {
            isLoadingDiff = false
            unifiedDiff = cached
            return
        }

        let scope = selectedScope
        let cwd = cwd
        isLoadingDiff = true
        diffErrorMessage = nil
        Task {
            do {
                let diff: String
                if let diffSession {
                    diff = try await diffSession.loadDiff(scope: scope, fileID: fileID)
                } else {
                    diff = try await provider.loadDiff(cwd: cwd, scope: scope, fileID: fileID)
                }
                guard diffGeneration == generation else { return }
                var scopedCache = diffCache[scope] ?? [:]
                scopedCache[fileID] = diff
                diffCache[scope] = scopedCache
                unifiedDiff = diff
                isLoadingDiff = false
            } catch {
                guard diffGeneration == generation else { return }
                unifiedDiff = ""
                isLoadingDiff = false
                diffErrorMessage = Self.displayMessage(for: error)
            }
        }
    }

    private func makeDiffSession() -> any PickyGitDiffReviewSessioning {
        if let factory = provider as? PickyGitDiffReviewSessionFactory {
            return factory.makeSession()
        }
        return PickyLegacyGitDiffReviewSession(provider: provider)
    }

    private func closeDiffSession() {
        guard let diffSession else { return }
        self.diffSession = nil
        Task { await diffSession.close() }
    }

    @discardableResult
    private func invalidateInFlightDiffLoad() -> UUID {
        let generation = UUID()
        diffGeneration = generation
        isLoadingDiff = false
        return generation
    }

    private static func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}

private final class PickyLegacyGitDiffReviewSession: PickyGitDiffReviewSessioning {
    private let provider: any PickyGitDiffReviewProviding
    private var cwd: String?

    init(provider: any PickyGitDiffReviewProviding) {
        self.provider = provider
    }

    func load(cwd: String) async throws -> PickyGitDiffViewerData {
        self.cwd = cwd
        return try await provider.load(cwd: cwd)
    }

    func loadDiff(scope: PickyGitDiffViewerScope, fileID: String) async throws -> String {
        guard let cwd else { throw PickyGitDiffReviewProviderError.notGitRepository }
        return try await provider.loadDiff(cwd: cwd, scope: scope, fileID: fileID)
    }

    func close() async {}
}

struct PickyDiffUnifiedDiffLine: Equatable, Identifiable {
    enum Kind: Equatable {
        case addition
        case deletion
        case hunk
        case fileHeader
        case context
    }

    let id: Int
    let text: String
    let kind: Kind

    static func lines(from diff: String) -> [PickyDiffUnifiedDiffLine] {
        diff.components(separatedBy: .newlines).enumerated().map { index, line in
            PickyDiffUnifiedDiffLine(id: index, text: line, kind: kind(for: line))
        }
    }

    static func kind(for line: String) -> Kind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("rename from ") || line.hasPrefix("rename to ") {
            return .fileHeader
        }
        if line.hasPrefix("+") { return .addition }
        if line.hasPrefix("-") { return .deletion }
        return .context
    }
}

struct PickyDiffViewerWindowView: View {
    @ObservedObject var model: PickyDiffViewerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Colors.borderSubtle)
            content
        }
        .background(PickyAppearancePanelChrome.overlayBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.Colors.accentText)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(model.repositoryTitle)
                        .font(PickyHUDTypography.metaMonospacedMedium)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Label(model.branchTitle, systemImage: "arrow.branch")
                    Text(model.summaryText)
                }
                .font(PickyHUDTypography.metaMonospacedMedium)
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            scopeToggle
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.textSecondary)
            .help("Refresh git diff")
            .disabled(model.isLoadingData)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var scopeToggle: some View {
        HStack(spacing: 0) {
            ForEach(PickyGitDiffViewerScope.allCases, id: \.self) { scope in
                scopeButton(scope)
            }
        }
        .background(Capsule().fill(DS.Colors.surface2.opacity(0.5)))
        .overlay(Capsule().stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5))
        .clipShape(Capsule())
    }

    private func scopeButton(_ scope: PickyGitDiffViewerScope) -> some View {
        let isActive = model.selectedScope == scope
        return Button {
            model.setScope(scope)
        } label: {
            Text(scope.title)
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(isActive ? DS.Colors.surface3.opacity(0.9) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(scope.accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingData {
            loadingState("Loading git diff…")
        } else if let error = model.errorMessage {
            errorState(title: "Unable to load git diff", message: error)
        } else if let scopeData = model.selectedScopeData, scopeData.files.isEmpty {
            emptyState
        } else {
            HSplitView {
                sidebar
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                diffPane
                    .frame(minWidth: 420)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(model.selectedScopeData?.files ?? []) { file in
                    fileRow(file)
                }
            }
            .padding(12)
        }
        .background(DS.Colors.surface1.opacity(0.45))
    }

    private func fileRow(_ file: PickyGitDiffFile) -> some View {
        let isSelected = model.selectedFileID == file.id
        return Button {
            model.selectFile(file)
        } label: {
            HStack(spacing: 8) {
                Text(file.status.shortLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(file.status))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(statusColor(file.status).opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.displayPath)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text("+\(file.insertions)")
                            .foregroundStyle(Color.green.opacity(0.9))
                        Text("-\(file.deletions)")
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                    .font(PickyHUDTypography.metaMonospacedMedium)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? DS.Colors.surface3.opacity(0.75) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? DS.Colors.borderSubtle.opacity(0.8) : Color.clear, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var diffPane: some View {
        if model.isLoadingDiff {
            loadingState("Loading file diff…")
        } else if let error = model.diffErrorMessage {
            errorState(title: "Unable to load file diff", message: error)
        } else if model.unifiedDiff.isEmpty {
            emptyDiffState
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(PickyDiffUnifiedDiffLine.lines(from: model.unifiedDiff)) { line in
                        diffLine(line)
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 18, trailing: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Colors.surface1.opacity(0.9))
        }
    }

    private func diffLine(_ line: PickyDiffUnifiedDiffLine) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 12, weight: fontWeight(for: line.kind), design: .monospaced))
            .foregroundStyle(foregroundColor(for: line.kind))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor(for: line.kind))
            .textSelection(.enabled)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DS.Colors.textTertiary)
            Text("No changes in \(model.selectedScope.title.lowercased()) diff")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
            Text(model.cwd)
                .font(PickyHUDTypography.metaMonospacedMedium)
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDiffState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(DS.Colors.textTertiary)
            Text("Select a file to view its unified diff")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingState(_ message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.orange)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusColor(_ status: PickyGitDiffChangeStatus) -> Color {
        switch status {
        case .modified: return Color.orange
        case .added: return Color.green
        case .deleted: return Color.red
        case .renamed: return Color.blue
        }
    }

    private func foregroundColor(for kind: PickyDiffUnifiedDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.95)
        case .deletion: return Color.red.opacity(0.92)
        case .hunk: return Color.purple.opacity(0.95)
        case .fileHeader: return DS.Colors.textSecondary
        case .context: return DS.Colors.textPrimary.opacity(0.9)
        }
    }

    private func backgroundColor(for kind: PickyDiffUnifiedDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.08)
        case .deletion: return Color.red.opacity(0.08)
        case .hunk: return Color.purple.opacity(0.08)
        case .fileHeader: return DS.Colors.surface2.opacity(0.55)
        case .context: return Color.clear
        }
    }

    private func fontWeight(for kind: PickyDiffUnifiedDiffLine.Kind) -> Font.Weight {
        switch kind {
        case .hunk, .fileHeader: return .semibold
        case .addition, .deletion, .context: return .regular
        }
    }
}
