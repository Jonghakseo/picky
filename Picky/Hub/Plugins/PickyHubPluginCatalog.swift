//
//  PickyHubPluginCatalog.swift
//  Picky
//
//  Catalog metadata (category, provider, use cases) layered on top of the
//  curated and bundled plugin lists, plus the shared search/filter model.
//  Bundled resources use the local installers; curated packages retain the
//  daemon-backed package flow.
//

import Combine
import Foundation
import SwiftUI

enum PickyHubPluginCategory: String, CaseIterable, Identifiable {
    case development
    case research
    case taskManagement
    case content

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .development: "hub.plugins.category.development"
        case .research: "hub.plugins.category.research"
        case .taskManagement: "hub.plugins.category.taskManagement"
        case .content: "hub.plugins.category.content"
        }
    }

    var title: String {
        switch self {
        case .development: L10n.t("hub.plugins.category.development")
        case .research: L10n.t("hub.plugins.category.research")
        case .taskManagement: L10n.t("hub.plugins.category.taskManagement")
        case .content: L10n.t("hub.plugins.category.content")
        }
    }
}

struct PickyHubPluginMetadata: Equatable {
    let category: PickyHubPluginCategory
    let provider: String
    let systemImage: String
    let useCaseKeys: [String]

    static let byPluginID: [String: PickyHubPluginMetadata] = [
        "picky-handoff": .init(
            category: .taskManagement, provider: "Picky", systemImage: "arrow.up.forward.app", useCaseKeys: []
        ),
        "picky-cli": .init(category: .taskManagement, provider: "Picky", systemImage: "terminal", useCaseKeys: []),
        "diff-review": .init(category: .development, provider: "@ryan_nookpi", systemImage: "arrow.left.arrow.right.square", useCaseKeys: ["hub.plugins.useCase.diffReview.1", "hub.plugins.useCase.diffReview.2"]),
        "ask-user-question": .init(category: .taskManagement, provider: "@ryan_nookpi", systemImage: "questionmark.bubble", useCaseKeys: ["hub.plugins.useCase.askUserQuestion.1", "hub.plugins.useCase.askUserQuestion.2"]),
        "generative-ui": .init(category: .content, provider: "@ryan_nookpi", systemImage: "rectangle.3.group", useCaseKeys: ["hub.plugins.useCase.generativeUI.1", "hub.plugins.useCase.generativeUI.2"]),
        "auto-name": .init(category: .taskManagement, provider: "@ryan_nookpi", systemImage: "textformat.abc", useCaseKeys: ["hub.plugins.useCase.autoName.1", "hub.plugins.useCase.autoName.2"]),
        "delayed-action": .init(category: .taskManagement, provider: "@ryan_nookpi", systemImage: "clock.arrow.circlepath", useCaseKeys: ["hub.plugins.useCase.delayedAction.1", "hub.plugins.useCase.delayedAction.2"]),
        "cron": .init(category: .taskManagement, provider: "@ryan_nookpi", systemImage: "calendar.badge.clock", useCaseKeys: ["hub.plugins.useCase.cron.1", "hub.plugins.useCase.cron.2"]),
        "memory-layer": .init(category: .research, provider: "@ryan_nookpi", systemImage: "brain", useCaseKeys: ["hub.plugins.useCase.memoryLayer.1", "hub.plugins.useCase.memoryLayer.2"]),
        "todo-write-overlay": .init(category: .taskManagement, provider: "@ryan_nookpi", systemImage: "checklist", useCaseKeys: ["hub.plugins.useCase.todoWriteOverlay.1", "hub.plugins.useCase.todoWriteOverlay.2"]),
        "subagent": .init(category: .development, provider: "@ryan_nookpi", systemImage: "person.2", useCaseKeys: ["hub.plugins.useCase.subagent.1", "hub.plugins.useCase.subagent.2"]),
        "clipboard": .init(category: .content, provider: "@ryan_nookpi", systemImage: "doc.on.clipboard", useCaseKeys: ["hub.plugins.useCase.clipboard.1", "hub.plugins.useCase.clipboard.2"]),
        "claude-mcp-bridge": .init(category: .development, provider: "@ryan_nookpi", systemImage: "point.3.connected.trianglepath.dotted", useCaseKeys: ["hub.plugins.useCase.claudeMcpBridge.1", "hub.plugins.useCase.claudeMcpBridge.2"]),
        "cross-agent": .init(category: .development, provider: "@ryan_nookpi", systemImage: "arrow.triangle.branch", useCaseKeys: ["hub.plugins.useCase.crossAgent.1", "hub.plugins.useCase.crossAgent.2"]),
        "claude-hooks-bridge": .init(category: .development, provider: "@ryan_nookpi", systemImage: "link", useCaseKeys: ["hub.plugins.useCase.claudeHooksBridge.1", "hub.plugins.useCase.claudeHooksBridge.2"]),
    ]

    static let fallback = PickyHubPluginMetadata(category: .development, provider: "npm", systemImage: "puzzlepiece.extension", useCaseKeys: [])

    static func metadata(for plugin: PickyCuratedPlugin) -> PickyHubPluginMetadata {
        byPluginID[plugin.id] ?? fallback
    }
}

/// One catalog entry as the pages render it.
struct PickyHubPluginItem: Identifiable, Equatable {
    let plugin: PickyCuratedPlugin
    let metadata: PickyHubPluginMetadata
    let status: PickyCuratedPluginInstaller.Status
    let installedVersion: String?
    let errorMessage: String?
    let successMessage: String?
    let progressMessage: String?
    let hasUpdate: Bool
    let isBusy: Bool
    var bundledStatus: PickyBundledPluginStatus?

    var canInstall: Bool {
        guard let bundledStatus else { return !isInstalled }
        return bundledStatus == .notInstalled || bundledStatus == .legacySymlink
    }
    var canRemove: Bool {
        guard let bundledStatus else { return isInstalled }
        return bundledStatus == .installed || bundledStatus == .outdated
    }
    var statusLabel: String {
        switch bundledStatus {
        case .outdated: return L10n.t("status.extensions.state.outdated")
        case .legacySymlink: return L10n.t("status.extensions.badge.legacySymlink")
        case .developerOverride: return L10n.t("status.extensions.badge.developerOverride")
        case .conflict: return L10n.t("status.extensions.badge.conflict")
        default: return L10n.t(isInstalled ? "hub.plugins.detail.installed" : "hub.plugins.detail.notInstalled")
        }
    }
    var statusTone: PickyHubInlineStatusTone {
        switch bundledStatus {
        case .conflict: return .error
        case .legacySymlink, .outdated: return .warning
        default: return .neutral
        }
    }
    var statusExplanation: String? {
        switch bundledStatus {
        case .developerOverride(let target): return L10n.t("status.extensions.state.developerOverride", target)
        case .conflict(let reason): return L10n.t("status.extensions.state.conflict", reason)
        case .legacySymlink: return L10n.t("status.extensions.state.legacySymlink")
        default: return nil
        }
    }

    var id: String { plugin.id }
    var title: String { L10n.t(plugin.titleKey) }
    var summary: String { L10n.t(plugin.descriptionKey) }
    var useCases: [String] { metadata.useCaseKeys.map { L10n.t($0) } }
    var isInstalled: Bool { status.isInstalled }
    /// "카테고리 · 제공자" (version is appended by the page when known).
    var metaLine: String { "\(metadata.category.title) · \(metadata.provider)" }

    static func == (lhs: PickyHubPluginItem, rhs: PickyHubPluginItem) -> Bool {
        lhs.plugin.id == rhs.plugin.id
            && lhs.status == rhs.status
            && lhs.installedVersion == rhs.installedVersion
            && lhs.errorMessage == rhs.errorMessage
            && lhs.successMessage == rhs.successMessage
            && lhs.progressMessage == rhs.progressMessage
            && lhs.hasUpdate == rhs.hasUpdate
            && lhs.isBusy == rhs.isBusy
            && lhs.bundledStatus == rhs.bundledStatus
    }
}

@MainActor
final class PickyHubPluginCatalogViewModel: ObservableObject {
    @Published var query = ""
    @Published var category: PickyHubPluginCategory?
    /// Human-readable outcome of the latest completed action, for the live region.
    @Published private(set) var feedback: String?
    @Published private(set) var feedbackIsError = false
    @Published private(set) var feedbackPluginID: String?
    /// Retained for existing consumers. Hub surfaces errors by plugin ID instead.
    @Published private(set) var lastError: String?

    let curated: PickyCuratedPluginsViewModel
    let bundled: PickyExtensionsSectionViewModel?
    private let pluginReloadController: PickyPluginReloadController
    private var cancellables: Set<AnyCancellable> = []
    private var pendingFeedbackByPluginID: [String: PendingFeedback] = [:]
    private var failedRetriesByPluginID: [String: () -> Void] = [:]
    @Published private var errorsByPluginID: [String: String] = [:]
    @Published private var successesByPluginID: [String: String] = [:]

    private struct PendingFeedback {
        let successKey: String
        let progressMessage: String?
        let title: String
        let retry: () -> Void
    }
    /// Dashboard shows these four in mockup order.
    static let recommendedIDs = ["diff-review", "ask-user-question", "generative-ui", "auto-name"]

    init(curated: PickyCuratedPluginsViewModel, pluginReloadController: PickyPluginReloadController,
         bundled: PickyExtensionsSectionViewModel? = nil) {
        self.bundled = bundled
        self.curated = curated
        self.pluginReloadController = pluginReloadController
        bundled?.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        bundled?.$mutationOutcome
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] outcome in self?.handleMutation(outcome) }
            .store(in: &cancellables)
        bundled?.onPluginStateChanged = { [pluginReloadController] in
            pluginReloadController.notePluginsChanged()
        }
        curated.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        curated.$mutationOutcome
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] outcome in self?.handleMutation(outcome) }
            .store(in: &cancellables)
        curated.onPluginStateChanged = { [pluginReloadController] in
            pluginReloadController.notePluginsChanged()
        }
    }

    var items: [PickyHubPluginItem] {
        bundledItems + curated.rows.map { row in
            PickyHubPluginItem(
                plugin: row.plugin,
                metadata: PickyHubPluginMetadata.metadata(for: row.plugin),
                status: row.status,
                installedVersion: row.installedVersion,
                errorMessage: errorsByPluginID[row.id],
                successMessage: successesByPluginID[row.id],
                progressMessage: pendingFeedbackByPluginID[row.id]?.progressMessage,
                hasUpdate: row.hasUpdate,
                isBusy: row.isBusy
            )
        }
    }

    private var bundledItems: [PickyHubPluginItem] {
        (bundled?.rows ?? []).filter { $0.status != .bundleMissing }.map { row in
            let key = row.kind == .extension ? "pickyHandoff" : "pickyCLI"
            let plugin = PickyCuratedPlugin(
                id: row.name, titleKey: "status.extensions.\(key).title",
                descriptionKey: "status.extensions.\(key).description",
                commandName: row.kind == .extension ? "/handoff-to-picky" : "/skill:picky-cli",
                source: "bundled:\(row.id)"
            )
            let installed = row.status == .installed || row.status == .outdated
            return PickyHubPluginItem(
                plugin: plugin, metadata: .metadata(for: plugin),
                status: installed ? .installed(isPinned: false) : .notInstalled,
                installedVersion: nil, errorMessage: errorsByPluginID[row.name],
                successMessage: successesByPluginID[row.name], progressMessage: nil,
                hasUpdate: row.status == .outdated, isBusy: row.isBusy, bundledStatus: row.status
            )
        }
    }

    var recommended: [PickyHubPluginItem] {
        let all = items
        return Self.recommendedIDs.compactMap { id in all.first { $0.id == id } }
    }

    var filtered: [PickyHubPluginItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            if let category, item.metadata.category != category { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [
                item.id, item.title, item.summary, item.metadata.category.title,
                item.metadata.provider, item.plugin.commandName
            ]
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(needle)
        }
    }

    func item(id: String) -> PickyHubPluginItem? {
        items.first { $0.id == id }
    }

    func refresh() {
        bundled?.refresh()
        curated.refresh()
        curated.checkUpdatesIfNeeded(pluginReloadController: pluginReloadController)
    }

    func install(_ item: PickyHubPluginItem) {
        if let row = bundled?.rows.first(where: { $0.name == item.id }) {
            guard self.item(id: item.id)?.canInstall == true else { return }
            beginMutation(
                item, successKey: "hub.plugins.feedback.installed",
                retry: { [weak self] in self?.install(item) },
                start: { bundled?.install(row) ?? false }
            )
            return
        }
        guard item.bundledStatus == nil else { return }
        beginMutation(item, successKey: "hub.plugins.feedback.installed", retry: { [weak self] in self?.install(item) }) {
            curated.install(item.plugin, pluginReloadController: pluginReloadController)
        }
    }

    func remove(_ item: PickyHubPluginItem) {
        if let row = bundled?.rows.first(where: { $0.name == item.id }) {
            guard self.item(id: item.id)?.canRemove == true else { return }
            beginMutation(
                item, successKey: "hub.plugins.feedback.removed",
                retry: { [weak self] in self?.remove(item) },
                start: { bundled?.uninstall(row) ?? false }
            )
            return
        }
        guard item.bundledStatus == nil else { return }
        beginMutation(item, successKey: "hub.plugins.feedback.removed", retry: { [weak self] in self?.remove(item) }) {
            curated.remove(item.plugin, pluginReloadController: pluginReloadController)
        }
    }

    func update(_ item: PickyHubPluginItem) {
        if let row = bundled?.rows.first(where: { $0.name == item.id }) {
            guard self.item(id: item.id)?.hasUpdate == true else { return }
            beginMutation(
                item, successKey: "hub.plugins.feedback.updated",
                retry: { [weak self] in self?.update(item) },
                start: { bundled?.install(row) ?? false }
            )
            return
        }
        guard item.bundledStatus == nil else { return }
        beginMutation(item, successKey: "hub.plugins.feedback.updated", retry: { [weak self] in self?.update(item) }) {
            curated.update(item.plugin, pluginReloadController: pluginReloadController)
        }
    }

    func setup(_ item: PickyHubPluginItem) {
        guard item.bundledStatus == nil else { return }
        beginMutation(
            item,
            successKey: "hub.plugins.feedback.setup",
            progressMessage: L10n.t("hub.plugins.feedback.settingUp"),
            retry: { [weak self] in self?.setup(item) }
        ) {
            curated.setup(item.plugin, pluginReloadController: pluginReloadController)
        }
    }

    func clearFilters() {
        query = ""
        category = nil
    }

    func error(for pluginID: String) -> String? {
        errorsByPluginID[pluginID]
    }

    private func beginMutation(
        _ item: PickyHubPluginItem,
        successKey: String,
        progressMessage: String? = nil,
        retry: @escaping () -> Void,
        start: () -> Bool
    ) {
        guard pendingFeedbackByPluginID[item.id] == nil else { return }
        pendingFeedbackByPluginID[item.id] = PendingFeedback(
            successKey: successKey, progressMessage: progressMessage, title: item.title, retry: retry
        )
        errorsByPluginID[item.id] = nil
        guard start() else {
            pendingFeedbackByPluginID[item.id] = nil
            return
        }
        successesByPluginID[item.id] = nil
        failedRetriesByPluginID[item.id] = nil
        feedback = nil
        feedbackPluginID = nil
        feedbackIsError = false
    }

    func retryFeedback() {
        guard feedbackIsError, let feedbackPluginID else { return }
        failedRetriesByPluginID[feedbackPluginID]?()
    }

    private func handleMutation(_ outcome: PickyCuratedPluginsViewModel.MutationOutcome) {
        let pending = pendingFeedbackByPluginID.removeValue(forKey: outcome.pluginID)
        switch outcome.result {
        case .success:
            errorsByPluginID[outcome.pluginID] = nil
            failedRetriesByPluginID[outcome.pluginID] = nil
            lastError = nil
            guard let pending else { return }
            feedbackPluginID = outcome.pluginID
            let message = L10n.t(pending.successKey, pending.title)
            successesByPluginID[outcome.pluginID] = message
            feedback = message
            feedbackIsError = false
        case .failure(let error):
            let message = error.localizedDescription
            errorsByPluginID[outcome.pluginID] = message
            lastError = message
            guard let pending else { return }
            failedRetriesByPluginID[outcome.pluginID] = pending.retry
            feedbackPluginID = outcome.pluginID
            feedback = L10n.t("hub.plugins.feedback.failed", pending.title, message)
            feedbackIsError = true
        }
    }
}
