//
//  PickyHubPluginCatalogTests.swift
//  PickyTests
//

import AppKit
import Foundation
import SwiftUI
import Vision
import Testing
@testable import Picky

@MainActor
struct PickyHubPluginCatalogTests {
    @Test func filtersBySearchAndCategory() {
        let catalog = makeCatalog(
            plugins: [PickyCuratedPlugin.diffReview, PickyCuratedPlugin.askUserQuestion]
        )

        catalog.query = "diff"
        #expect(catalog.filtered.map(\.id) == ["diff-review"])

        catalog.query = ""
        catalog.category = .taskManagement
        #expect(catalog.filtered.map(\.id) == ["ask-user-question"])
    }

    @Test func clearFiltersRestoresEveryCatalogItem() {
        let catalog = makeCatalog(
            plugins: [PickyCuratedPlugin.diffReview, PickyCuratedPlugin.askUserQuestion]
        )
        catalog.query = "diff"
        catalog.category = .development

        catalog.clearFilters()

        #expect(catalog.query.isEmpty)
        #expect(catalog.category == nil)
        #expect(catalog.filtered.map(\.id) == ["diff-review", "ask-user-question"])
    }

    @Test func recommendedItemsFollowDeclaredCatalogOrder() {
        let catalog = makeCatalog(
            plugins: [
                PickyCuratedPlugin.autoName,
                PickyCuratedPlugin.generativeUI,
                PickyCuratedPlugin.askUserQuestion,
                PickyCuratedPlugin.diffReview
            ]
        )

        #expect(catalog.recommended.map(\.id) == PickyHubPluginCatalogViewModel.recommendedIDs)
    }

    @Test func installPublishesLocalizedSuccessFeedback() async throws {
        let client = HubPluginFanoutClient()
        var installed = false
        let plugin = PickyCuratedPlugin.diffReview
        let curated = PickyCuratedPluginsViewModel(
            plugins: [plugin],
            statusForSource: { _ in installed ? .installed(isPinned: false) : .notInstalled }
        )
        let reloadController = PickyPluginReloadController(client: client)
        let catalog = PickyHubPluginCatalogViewModel(curated: curated, pluginReloadController: reloadController)
        client.beforeSend = { command in
            await MainActor.run {
                installed = true
                client.emit(.protocolEvent(PickyEventEnvelope(
                    id: "plugin-install-complete",
                    protocolVersion: pickyAgentProtocolVersion,
                    timestamp: Date(),
                    event: .packageOperationCompleted(PickyPackageOperationCompletedEvent(
                        requestId: command.id,
                        operation: .install,
                        source: plugin.source,
                        ok: true,
                        errorMessage: nil
                    ))
                )))
            }
        }

        guard let item = catalog.item(id: plugin.id) else {
            Issue.record("Expected curated plugin item")
            return
        }
        catalog.install(item)
        try await waitUntil { catalog.feedback != nil }

        #expect(catalog.feedback == L10n.t("hub.plugins.feedback.installed", item.title))
        #expect(catalog.lastError == nil)
    }

    @Test func concurrentSuccessThenFailureKeepsTheFailureOnItsOriginatingPlugin() async throws {
        let first = PickyCuratedPlugin.diffReview
        let second = PickyCuratedPlugin.askUserQuestion
        let client = HubPluginFanoutClient()
        let catalog = makeCatalog(plugins: [first, second], client: client)
        let firstItem = try #require(catalog.item(id: first.id))
        let secondItem = try #require(catalog.item(id: second.id))

        catalog.install(firstItem)
        catalog.install(secondItem)
        try await waitUntil { client.sentCommands.count == 2 }
        let commands = client.sentCommands
        let firstCommand = try #require(commands.first { $0.source == first.source })
        let secondCommand = try #require(commands.first { $0.source == second.source })

        client.complete(firstCommand, operation: .install, ok: true)
        try await waitUntil { catalog.feedback == L10n.t("hub.plugins.feedback.installed", firstItem.title) }
        client.complete(secondCommand, operation: .install, ok: false, errorMessage: "Second package failed")
        try await waitUntil { catalog.error(for: second.id) != nil }

        #expect(catalog.error(for: first.id) == nil)
        #expect(catalog.error(for: second.id) == "Second package failed")
        #expect(catalog.item(id: second.id)?.errorMessage == "Second package failed")
        #expect(catalog.feedback == L10n.t("hub.plugins.feedback.failed", secondItem.title, "Second package failed"))
        #expect(catalog.feedbackIsError)
    }

    @Test func concurrentFailureThenSuccessDoesNotClearAnotherPluginsVisibleError() async throws {
        let first = PickyCuratedPlugin.diffReview
        let second = PickyCuratedPlugin.askUserQuestion
        let client = HubPluginFanoutClient()
        let catalog = makeCatalog(plugins: [first, second], client: client)
        let firstItem = try #require(catalog.item(id: first.id))
        let secondItem = try #require(catalog.item(id: second.id))

        catalog.install(firstItem)
        catalog.install(secondItem)
        try await waitUntil { client.sentCommands.count == 2 }
        let commands = client.sentCommands
        let firstCommand = try #require(commands.first { $0.source == first.source })
        let secondCommand = try #require(commands.first { $0.source == second.source })

        client.complete(secondCommand, operation: .install, ok: false, errorMessage: "Second package failed")
        try await waitUntil { catalog.error(for: second.id) != nil }
        client.complete(firstCommand, operation: .install, ok: true)
        try await waitUntil { catalog.feedback == L10n.t("hub.plugins.feedback.installed", firstItem.title) }

        #expect(catalog.error(for: first.id) == nil)
        #expect(catalog.error(for: second.id) == "Second package failed")
        #expect(catalog.item(id: second.id)?.errorMessage == "Second package failed")
        #expect(catalog.feedbackIsError == false)
    }

    @Test func catalogProjectsOnlyTheResolvedInstalledVersion() {
        let plugin = PickyCuratedPlugin.diffReview
        let client = HubPluginFanoutClient()
        let curated = PickyCuratedPluginsViewModel(
            plugins: [plugin],
            statusForSource: { _ in .installed(isPinned: false) },
            installedVersionForSource: { _ in "2.4.1" }
        )
        let catalog = PickyHubPluginCatalogViewModel(
            curated: curated,
            pluginReloadController: PickyPluginReloadController(client: client)
        )

        #expect(catalog.item(id: plugin.id)?.installedVersion == "2.4.1")
    }

    @Test func repeatedActionForABusyPluginSendsOnlyOneDaemonCommand() async throws {
        let plugin = PickyCuratedPlugin.diffReview
        let client = HubPluginFanoutClient()
        let catalog = makeCatalog(plugins: [plugin], client: client)
        let item = try #require(catalog.item(id: plugin.id))

        catalog.install(item)
        catalog.install(item)
        try await waitUntil { client.sentCommands.count == 1 }
        let command = try #require(client.sentCommands.first)
        client.complete(command, operation: .install, ok: true)
        try await waitUntil { catalog.feedback != nil }

        #expect(client.sentCommands.count == 1)
        #expect(catalog.feedback == L10n.t("hub.plugins.feedback.installed", item.title))
    }

    @Test func retryTargetsTheFailedPluginWhileAnotherPluginIsStillRunning() async throws {
        let client = HubPluginFanoutClient()
        let catalog = makeCatalog(plugins: [.diffReview, .askUserQuestion], client: client)
        let first = try #require(catalog.item(id: PickyCuratedPlugin.diffReview.id))
        let second = try #require(catalog.item(id: PickyCuratedPlugin.askUserQuestion.id))
        catalog.install(first)
        catalog.install(second)
        try await waitUntil { client.sentCommands.count == 2 }
        let firstCommand = try #require(client.sentCommands.first { $0.source == first.plugin.source })
        client.complete(firstCommand, operation: .install, ok: false, errorMessage: "First failed")
        try await waitUntil { catalog.feedbackIsError }
        #expect(catalog.feedbackPluginID == first.id)
        catalog.retryFeedback()
        try await waitUntil { client.sentCommands.count == 3 }
        #expect(client.sentCommands.last?.source == first.plugin.source)
        #expect(catalog.item(id: second.id)?.isBusy == true)
        for command in client.sentCommands where command.id != firstCommand.id {
            client.complete(command, operation: .install, ok: true)
        }
        try await waitUntil { catalog.items.allSatisfy { !$0.isBusy } }
    }

    @Test func setupFailurePublishesFeedbackAndThePluginsOwnError() async throws {
        let plugin = PickyCuratedPlugin.cron
        let client = HubPluginFanoutClient()
        let catalog = makeCatalog(plugins: [plugin], client: client, status: .installed(isPinned: false))
        let item = try #require(catalog.item(id: plugin.id))

        catalog.setup(item)
        try await waitUntil { client.sentCommands.count == 1 }
        let command = try #require(client.sentCommands.first)
        client.complete(command, operation: .setup, ok: false, errorMessage: "Cron daemon unavailable")
        try await waitUntil { catalog.error(for: plugin.id) != nil }

        #expect(catalog.error(for: plugin.id) == "Cron daemon unavailable")
        #expect(catalog.feedback == L10n.t("hub.plugins.feedback.failed", item.title, "Cron daemon unavailable"))
        #expect(catalog.feedbackIsError)
    }

    @Test func setupSuccessStaysOnItsCardAcrossOtherPluginOperationsAndRepeatedSetup() async throws {
        let client = HubPluginFanoutClient()
        let catalog = makeCatalog(plugins: [.cron, .diffReview], client: client, status: .installed(isPinned: false))
        let cron = try #require(catalog.item(id: "cron"))
        let other = try #require(catalog.item(id: "diff-review"))
        let success = L10n.t("hub.plugins.feedback.setup", cron.title)

        catalog.setup(cron)
        #expect(catalog.item(id: cron.id)?.progressMessage == L10n.t("hub.plugins.feedback.settingUp"))
        #expect(catalog.item(id: cron.id)?.isBusy == true)
        try await waitUntil { client.sentCommands.count == 1 }
        let setup = try #require(client.sentCommands.first)
        #expect(setup.type == .setupPackage)
        client.complete(setup, operation: .setup, ok: true)
        try await waitUntil { catalog.item(id: cron.id)?.successMessage == success }
        #expect(catalog.item(id: cron.id)?.progressMessage == nil)
        #expect(catalog.item(id: cron.id)?.isInstalled == true)

        catalog.update(other)
        try await waitUntil { client.sentCommands.count == 2 }
        client.complete(try #require(client.sentCommands.last), operation: .update, ok: true)
        try await waitUntil { catalog.item(id: other.id)?.successMessage != nil }
        #expect(catalog.item(id: cron.id)?.successMessage == success)

        catalog.setup(cron)
        #expect(catalog.item(id: cron.id)?.successMessage == nil)
        #expect(catalog.item(id: cron.id)?.progressMessage != nil)
        try await waitUntil { client.sentCommands.count == 3 }
        client.complete(try #require(client.sentCommands.last), operation: .setup, ok: true)
        try await waitUntil { catalog.item(id: cron.id)?.successMessage == success }
        #expect(catalog.item(id: cron.id)?.isBusy == false)
    }

    @Test func failedSetupCanBeRetriedWithoutKeepingStaleCardFeedback() async throws {
        let client = HubPluginFanoutClient()
        let catalog = makeCatalog(plugins: [.cron], client: client, status: .installed(isPinned: false))
        let cron = try #require(catalog.item(id: "cron"))
        catalog.setup(cron)
        try await waitUntil { client.sentCommands.count == 1 }
        client.complete(
            try #require(client.sentCommands.first), operation: .setup, ok: false, errorMessage: "Daemon unavailable"
        )
        try await waitUntil { catalog.feedbackIsError }
        #expect(catalog.item(id: cron.id)?.errorMessage == "Daemon unavailable")
        #expect(catalog.item(id: cron.id)?.progressMessage == nil)
        #expect(catalog.item(id: cron.id)?.successMessage == nil)

        catalog.retryFeedback()
        #expect(catalog.item(id: cron.id)?.errorMessage == nil)
        #expect(catalog.item(id: cron.id)?.progressMessage != nil)
        try await waitUntil { client.sentCommands.count == 2 }
        client.complete(try #require(client.sentCommands.last), operation: .setup, ok: true)
        try await waitUntil { catalog.item(id: cron.id)?.successMessage != nil }
        #expect(catalog.item(id: cron.id)?.errorMessage == nil)
        #expect(catalog.item(id: cron.id)?.progressMessage == nil)
    }

    @Test func cronCardRendersCommonActionsAndDaemonFeedbackFromCompletionEvents() async throws {
        let client = HubPluginFanoutClient()
        let catalog = makeCatalog(plugins: [.cron], client: client, status: .installed(isPinned: false))
        let cron = try #require(catalog.item(id: "cron"))

        catalog.setup(cron)
        try await waitUntil { client.sentCommands.count == 1 }
        try renderCronCard(catalog, state: "setting-up", expectedText: L10n.t("hub.plugins.feedback.settingUp"))
        client.complete(
            try #require(client.sentCommands.first), operation: .setup, ok: false, errorMessage: "Daemon unavailable"
        )
        try await waitUntil { catalog.feedbackIsError }
        try renderCronCard(catalog, state: "failed", expectedText: "Daemon unavailable")

        catalog.retryFeedback()
        try await waitUntil { client.sentCommands.count == 2 }
        client.complete(try #require(client.sentCommands.last), operation: .setup, ok: true)
        try await waitUntil { catalog.item(id: cron.id)?.successMessage != nil }
        try renderCronCard(catalog, state: "succeeded", expectedText: L10n.t("hub.plugins.feedback.setup", cron.title))
    }

    private func renderCronCard(_ catalog: PickyHubPluginCatalogViewModel, state: String, expectedText: String) throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/render-gallery/cron-feedback", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (width, scale, appearance) in [(420.0, 1.0, NSAppearance.Name.aqua), (320.0, 1.3, .darkAqua)] {
            let size = CGSize(width: width, height: 640)
            let root = CronCardFixture(catalog: catalog)
                .environment(\.locale, LocaleManager.shared.effectiveLocale)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.pickyAppFontScale, scale)
                .padding(PickyHubTheme.Spacing.field)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(
                root, logicalSize: size, scale: 2, appearance: appearance
            ))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let visibleWords = text.filter { $0.isLetter || $0.isNumber }
            let expectedWords = expectedText.filter { $0.isLetter || $0.isNumber }
            #expect(visibleWords.localizedCaseInsensitiveContains(expectedWords), "Missing card feedback: \(text)")
            #expect(text.contains(L10n.t("hub.plugins.card.viewJobs")), "Cron jobs must remain accessible")
            #expect(text.contains(L10n.t("hub.plugins.card.setupDaemon")), "Daemon setup must be a visible action")
            #expect(
                text.components(separatedBy: L10n.t("hub.plugins.detail.installed")).count >= 3,
                "Both the installed badge and common removal control must be visible: \(text)"
            )
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("cron-\(state)-\(Int(width))-\(Int(scale * 100)).png"))
        }
    }

    private func makeCatalog(
        plugins: [PickyCuratedPlugin],
        client: HubPluginFanoutClient = HubPluginFanoutClient(),
        status: PickyCuratedPluginInstaller.Status = .notInstalled
    ) -> PickyHubPluginCatalogViewModel {
        let reloadController = PickyPluginReloadController(client: client)
        let curated = PickyCuratedPluginsViewModel(
            plugins: plugins,
            statusForSource: { _ in status }
        )
        return PickyHubPluginCatalogViewModel(curated: curated, pluginReloadController: reloadController)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Timed out waiting for plugin catalog feedback")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class HubPluginFanoutClient: PickyAgentClient, @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [AsyncStream<PickyClientEvent>.Continuation] = []
    private var commands: [PickyCommandEnvelope] = []
    @MainActor var beforeSend: ((PickyCommandEnvelope) async -> Void)?

    var events: AsyncStream<PickyClientEvent> {
        AsyncStream { continuation in lock.withLock { subscribers.append(continuation) } }
    }

    var sentCommands: [PickyCommandEnvelope] { lock.withLock { commands } }

    func connect() async { emit(.connected) }
    func disconnect() {
        let continuations = lock.withLock { subscribers }
        for continuation in continuations { continuation.finish() }
    }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "unused", message: "unused")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        lock.withLock { commands.append(command) }
        let callback = await MainActor.run { beforeSend }
        await callback?(command)
    }
    func emit(_ event: PickyClientEvent) {
        for continuation in lock.withLock({ subscribers }) { continuation.yield(event) }
    }

    func complete(
        _ command: PickyCommandEnvelope,
        operation: PickyPackageOperation,
        ok: Bool,
        errorMessage: String? = nil
    ) {
        emit(.protocolEvent(PickyEventEnvelope(
            id: "plugin-complete-\(command.id)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: .packageOperationCompleted(PickyPackageOperationCompletedEvent(
                requestId: command.id,
                operation: operation,
                source: command.source ?? "",
                ok: ok,
                errorMessage: errorMessage
            ))
        )))
    }
}

private struct CronCardFixture: View {
    @ObservedObject var catalog: PickyHubPluginCatalogViewModel
    @FocusState private var focusedControl: String?

    var body: some View {
        if let item = catalog.item(id: "cron") {
            PickyHubPluginCardView(
                item: item, onDetail: {}, onInstall: {}, onRemove: {}, onUpdate: {},
                onViewCronJobs: {}, onSetupCronDaemon: { catalog.setup(item) },
                focusedControl: $focusedControl
            )
        }
    }
}
