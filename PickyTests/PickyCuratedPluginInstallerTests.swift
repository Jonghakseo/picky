//
//  PickyCuratedPluginInstallerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyCuratedPluginInstallerTests {
    private let source = "npm:@ryan_nookpi/pi-extension-diff-review"

    @Test func curatedDefaultsIncludeSubagentWithExpectedSource() {
        let subagent = PickyCuratedPlugin.curatedDefaults.first { $0.id == "subagent" }

        #expect(subagent?.source == "npm:@ryan_nookpi/pi-extension-subagent")
    }

    @Test func curatedDefaultsIncludeCronAndMemoryLayer() {
        let cron = PickyCuratedPlugin.curatedDefaults.first { $0.id == "cron" }
        let memory = PickyCuratedPlugin.curatedDefaults.first { $0.id == "memory-layer" }

        #expect(cron?.source == "npm:@ryan_nookpi/pi-extension-cron")
        #expect(cron?.kind == .cron)
        #expect(memory?.source == "npm:@ryan_nookpi/pi-extension-memory-layer")
    }

    @Test func statusReportsNotInstalledWhenSettingsAreMissing() throws {
        let scratch = try ScratchCuratedPlugin()

        let status = PickyCuratedPluginInstaller.status(
            source: source,
            homeURL: scratch.home,
            preferences: PickyPiInstallationPreferences(codingAgentDir: scratch.home.appendingPathComponent(".pi/agent").path)
        )

        #expect(status == .notInstalled)
    }

    @Test func statusReportsInstalledWhenSourceIsInSettingsPackages() throws {
        let scratch = try ScratchCuratedPlugin()
        try scratch.writeSettings(packages: ["npm:@example/other", source])

        let status = PickyCuratedPluginInstaller.status(
            source: source,
            homeURL: scratch.home,
            preferences: PickyPiInstallationPreferences(codingAgentDir: scratch.home.appendingPathComponent(".pi/agent").path)
        )

        #expect(status == .installed(isPinned: false))
    }

    @Test func statusReportsPinnedPackageAsInstalled() throws {
        let scratch = try ScratchCuratedPlugin()
        try scratch.writeSettings(packages: ["\(source)@1.2.3"])

        let status = PickyCuratedPluginInstaller.status(
            source: source,
            homeURL: scratch.home,
            preferences: PickyPiInstallationPreferences(codingAgentDir: scratch.home.appendingPathComponent(".pi/agent").path)
        )

        #expect(status == .installed(isPinned: true))
    }

    @Test func statusPinsOnlyExactSemverSources() throws {
        for (suffix, isPinned) in [("@1.2.3", true), ("@^1.2.0", false), ("@latest", false), ("", false)] {
            let scratch = try ScratchCuratedPlugin()
            try scratch.writeSettings(packages: ["\(source)\(suffix)"])

            let status = PickyCuratedPluginInstaller.status(
                source: source,
                homeURL: scratch.home,
                preferences: PickyPiInstallationPreferences(codingAgentDir: scratch.home.appendingPathComponent(".pi/agent").path)
            )

            #expect(status == .installed(isPinned: isPinned))
        }
    }

    @Test func statusUsesConfiguredPiCodingAgentDir() throws {
        let scratch = try ScratchCuratedPlugin()
        let customAgentDir = scratch.tmp.appendingPathComponent("custom-agent", isDirectory: true)
        try scratch.writeSettings(packages: [source], agentDir: customAgentDir)

        let status = PickyCuratedPluginInstaller.status(
            source: source,
            homeURL: scratch.home,
            preferences: PickyPiInstallationPreferences(codingAgentDir: customAgentDir.path)
        )

        #expect(status == .installed(isPinned: false))
    }

    @Test func installedVersionReadsTheResolvedScopedPackageManifest() throws {
        let scratch = try ScratchCuratedPlugin()
        let agentDir = scratch.home.appendingPathComponent(".pi/agent", isDirectory: true)
        try scratch.writeSettings(packages: ["\(source)@^1.0.0"], agentDir: agentDir)
        try scratch.writePackageManifest(
            packageName: "@ryan_nookpi/pi-extension-diff-review",
            version: "2.4.1",
            agentDir: agentDir
        )

        let version = PickyCuratedPluginInstaller.installedVersion(
            source: source,
            homeURL: scratch.home,
            preferences: PickyPiInstallationPreferences(codingAgentDir: agentDir.path)
        )

        #expect(version == "2.4.1")
    }

    @Test func installedVersionOmitsStaleOrWrongPackageManifests() throws {
        let scratch = try ScratchCuratedPlugin()
        let agentDir = scratch.home.appendingPathComponent(".pi/agent", isDirectory: true)
        try scratch.writeSettings(packages: [source], agentDir: agentDir)
        try scratch.writePackageManifest(
            packageName: "@ryan_nookpi/pi-extension-diff-review",
            manifestName: "@ryan_nookpi/another-package",
            version: "2.4.1",
            agentDir: agentDir
        )

        let wrongNameVersion = PickyCuratedPluginInstaller.installedVersion(
            source: source,
            homeURL: scratch.home,
            preferences: PickyPiInstallationPreferences(codingAgentDir: agentDir.path)
        )
        let missingPackageVersion = PickyCuratedPluginInstaller.installedVersion(
            source: "npm:@ryan_nookpi/pi-extension-cron",
            homeURL: scratch.home,
            preferences: PickyPiInstallationPreferences(codingAgentDir: agentDir.path)
        )

        #expect(wrongNameVersion == nil)
        #expect(missingPackageVersion == nil)
    }

    @Test func installSendsPackageCommandAndWaitsForDaemonCompletion() async throws {
        let client = FakeCuratedPluginAgentClient()
        var sentCommand: PickyCommandEnvelope?
        client.sendHandler = { command in
            sentCommand = command
            client.complete(requestId: command.id, operation: .install, source: command.source ?? "", ok: true)
        }

        let result = await PickyCuratedPluginInstaller.install(source: source, client: client)

        #expect(sentCommand?.type == .installPackage)
        #expect(sentCommand?.source == source)
        #expect(throws: Never.self) { try result.get() }
    }

    @Test func setupSendsSetupOnlyCommandAndWaitsForDaemonCompletion() async throws {
        let client = FakeCuratedPluginAgentClient()
        var sentCommand: PickyCommandEnvelope?
        client.sendHandler = { command in
            sentCommand = command
            client.complete(requestId: command.id, operation: .setup, source: command.source ?? "", ok: true, packageChanged: false)
        }

        let result = await PickyCuratedPluginInstaller.setup(source: source, client: client)

        #expect(sentCommand?.type == .setupPackage)
        #expect(sentCommand?.source == source)
        #expect(throws: Never.self) { try result.get() }
    }

    @Test func installReportsStructuredPartialFailureWhenPackageChangedBeforeSetupFailed() async {
        let client = FakeCuratedPluginAgentClient()
        client.sendHandler = { command in
            client.complete(
                requestId: command.id,
                operation: .install,
                source: command.source ?? "",
                ok: false,
                errorMessage: "LaunchAgent did not load",
                packageChanged: true
            )
        }

        let result = await PickyCuratedPluginInstaller.install(source: source, client: client)

        if case .failure(.rejected(let rejection)) = result {
            #expect(rejection.detail == "LaunchAgent did not load")
            #expect(rejection.packageChanged)
            #expect(result.failureMessage == L10n.t("hub.plugins.error.partial"))
        } else {
            Issue.record("Expected structured partial failure")
        }
    }

    @Test func legacyFailureWithoutPackageChangedRemainsGeneric() async {
        let client = FakeCuratedPluginAgentClient()
        client.sendHandler = { command in
            client.complete(
                requestId: command.id,
                operation: .install,
                source: command.source ?? "",
                ok: false,
                errorMessage: "Package operation failed"
            )
        }

        let result = await PickyCuratedPluginInstaller.install(source: source, client: client)

        if case .failure(.rejected(let rejection)) = result {
            #expect(rejection.detail == "Package operation failed")
            #expect(rejection.code == nil)
            #expect(result.failureMessage == L10n.t("hub.plugins.error.failed.install"))
        } else {
            Issue.record("Expected generic legacy failure")
        }
    }

    @Test(arguments: [
        ("duplicate", "hub.plugins.error.duplicate"),
        ("held", "hub.plugins.error.held"),
        ("timeout", "hub.plugins.error.timeout"),
        ("some-future-code", "hub.plugins.error.failed.install"),
    ])
    func classifiedDaemonFailuresShowUserWordingInsteadOfRawOutput(code: String, messageKey: String) async {
        let rawOutput = "/Applications/Picky.app/Contents/Resources/agentd-runtime/bin/node npm-command-runner.js -- npm install failed with code 1"
        let client = FakeCuratedPluginAgentClient()
        client.sendHandler = { command in
            client.complete(requestId: command.id, operation: .install, source: command.source ?? "", ok: false, errorMessage: rawOutput, errorCode: code)
        }

        let result = await PickyCuratedPluginInstaller.install(source: source, client: client)

        #expect(result.failureMessage == L10n.t(messageKey))
        #expect(result.failureMessage?.contains("npm-command-runner") == false)
    }

    @Test func checkUpdatesReturnsSourcesFromMatchingDaemonResponse() async {
        let client = FakeCuratedPluginAgentClient()
        var sentCommand: PickyCommandEnvelope?
        client.sendHandler = { command in
            sentCommand = command
            client.availableUpdates(commandId: command.id, sources: [self.source])
        }

        let result = await PickyCuratedPluginInstaller.checkUpdates(client: client)

        #expect(sentCommand?.type == .checkPackageUpdates)
        #expect((try? result.get()) == Set([source]))
    }

    @Test func checkUpdatesReturnsFailureWhenDisconnected() async {
        let client = FakeCuratedPluginAgentClient()
        client.sendHandler = { _ in client.emitDisconnected() }

        let result = await PickyCuratedPluginInstaller.checkUpdates(client: client)

        #expect(result == .failure(.disconnected))
    }

    @Test func checkUpdatesReturnsFailureWhenDaemonCouldNotQueryRegistry() async {
        let client = FakeCuratedPluginAgentClient()
        client.sendHandler = { command in
            client.availableUpdates(commandId: command.id, sources: [], failed: true)
        }

        let result = await PickyCuratedPluginInstaller.checkUpdates(client: client)

        #expect(result == .failure(.failed("Package update check failed.")))
    }

    @Test @MainActor func availableUpdateSourcesMarkOnlyInstalledCuratedRowsAsUpdatable() {
        let source = "npm:@example/curated-plugin"
        let plugin = PickyCuratedPlugin(
            id: "test-plugin",
            titleKey: "extensions.curated.diffReview.title",
            descriptionKey: "extensions.curated.diffReview.description",
            commandName: "/test-plugin",
            source: source
        )
        let notInstalledPlugin = PickyCuratedPlugin(
            id: "not-installed-plugin",
            titleKey: "extensions.curated.diffReview.title",
            descriptionKey: "extensions.curated.diffReview.description",
            commandName: "/not-installed-plugin",
            source: "npm:@example/not-installed-plugin"
        )
        let viewModel = PickyCuratedPluginsViewModel(
            plugins: [plugin, notInstalledPlugin],
            statusForSource: { source in source == plugin.source ? .installed(isPinned: false) : .notInstalled }
        )

        viewModel.applyAvailableUpdates([source, notInstalledPlugin.source])

        #expect(viewModel.rows.first?.hasUpdate == true)
        #expect(viewModel.rows.last?.hasUpdate == false)
    }

    @Test @MainActor func availableUpdateSourcesExcludePinnedCuratedRows() {
        let plugin = PickyCuratedPlugin(
            id: "pinned-plugin",
            titleKey: "extensions.curated.diffReview.title",
            descriptionKey: "extensions.curated.diffReview.description",
            commandName: "/pinned-plugin",
            source: source
        )
        let viewModel = PickyCuratedPluginsViewModel(
            plugins: [plugin],
            statusForSource: { _ in .installed(isPinned: true) }
        )

        viewModel.applyAvailableUpdates([source])

        #expect(viewModel.rows.first?.hasUpdate == false)
    }

    @Test @MainActor func duplicateOwnersBlockCatalogInstallUntilTheOtherCopyIsGone() async throws {
        let plugin = PickyCuratedPlugin.excalidraw
        let localCopy = "/Users/example/.pi/agent/skills/excalidraw/SKILL.md"
        let client = FakeCuratedPluginAgentClient()
        let controller = PickyPluginReloadController(client: client)
        var reportedConflicts = [PickyPackageConflict(source: plugin.source, kind: .skill, name: "excalidraw", ownerPath: localCopy)]
        var sentTypes: [PickyCommandType] = []
        var inspectedSources: [String] = []
        client.sendHandler = { command in
            sentTypes.append(command.type)
            switch command.type {
            case .inspectPackageConflicts:
                inspectedSources = command.sources ?? []
                client.conflicts(commandId: command.id, conflicts: reportedConflicts)
            case .checkPackageUpdates:
                client.availableUpdates(commandId: command.id, sources: [])
            case .installPackage:
                client.complete(requestId: command.id, operation: .install, source: command.source ?? "", ok: true)
            default:
                break
            }
        }
        let curated = PickyCuratedPluginsViewModel(
            plugins: [.diffReview, plugin],
            statusForSource: { _ in .notInstalled },
            installedVersionForSource: { _ in nil }
        )
        let catalog = PickyHubPluginCatalogViewModel(curated: curated, pluginReloadController: controller)

        catalog.refresh()
        try await waitUntil { catalog.item(id: plugin.id)?.conflicts.isEmpty == false }

        #expect(inspectedSources == [plugin.source])
        let blocked = try #require(catalog.item(id: plugin.id))
        #expect(blocked.canInstall == false)
        #expect(blocked.statusExplanation?.contains(localCopy) == true)
        #expect(catalog.item(id: "diff-review")?.canInstall == true)

        catalog.install(blocked)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!sentTypes.contains(.installPackage))
        #expect(catalog.item(id: plugin.id)?.isBusy == false)

        reportedConflicts = []
        catalog.refresh()
        try await waitUntil { catalog.item(id: plugin.id)?.canInstall == true }
        catalog.install(try #require(catalog.item(id: plugin.id)))
        try await waitUntil { sentTypes.contains(.installPackage) }
    }

    @Test @MainActor func removeDuplicatesClearsRemovableCopiesAndKeepsManualOnesReported() async throws {
        let plugin = PickyCuratedPlugin.webAccess
        let localCopy = "/Users/example/.pi/agent/extensions/web-access"
        let sharedCopy = "/Users/example/shared/web-tools"
        let client = FakeCuratedPluginAgentClient()
        let controller = PickyPluginReloadController(client: client)
        var reportedConflicts = [
            PickyPackageConflict(source: plugin.source, kind: .tool, name: "web_search", ownerPath: localCopy, removal: .trash(path: localCopy)),
            PickyPackageConflict(source: plugin.source, kind: .tool, name: "fetch_content", ownerPath: localCopy, removal: .trash(path: localCopy)),
            PickyPackageConflict(source: plugin.source, kind: .tool, name: "web_search", ownerPath: "/pkg/pi-web-access", removal: .package(source: "npm:pi-web-access")),
            PickyPackageConflict(source: plugin.source, kind: .tool, name: "get_search_content", ownerPath: sharedCopy, removal: .manual)
        ]
        var removedSources: [String] = []
        var trashed: [URL] = []
        var changeCount = 0
        client.sendHandler = { command in
            switch command.type {
            case .inspectPackageConflicts:
                client.conflicts(commandId: command.id, conflicts: reportedConflicts)
            case .removePackage:
                removedSources.append(command.source ?? "")
                client.complete(requestId: command.id, operation: .remove, source: command.source ?? "", ok: true)
            default:
                break
            }
        }
        let viewModel = PickyCuratedPluginsViewModel(
            plugins: [plugin],
            statusForSource: { _ in .notInstalled },
            installedVersionForSource: { _ in nil },
            trashItem: { trashed.append($0) }
        )
        viewModel.onPluginStateChanged = { changeCount += 1 }
        viewModel.inspectConflicts(pluginReloadController: controller)
        try await waitUntil { viewModel.rows.first?.conflicts.count == 4 }

        reportedConflicts = [reportedConflicts[3]]
        #expect(viewModel.removeDuplicates(plugin, pluginReloadController: controller))
        try await waitUntil { viewModel.mutationOutcome != nil && viewModel.rows.first?.conflicts.count == 1 }

        #expect(removedSources == ["npm:pi-web-access"])
        #expect(trashed == [URL(fileURLWithPath: localCopy)])
        #expect(changeCount == 1)
        #expect(viewModel.rows.first?.isBusy == false)
        guard case .failure(let error)? = viewModel.mutationOutcome?.result else {
            Issue.record("Expected the manual copy to be reported as remaining")
            return
        }
        #expect(error.localizedDescription.contains(sharedCopy))
        #expect(viewModel.removeDuplicates(plugin, pluginReloadController: controller) == false)
    }

    @Test func duplicateTrashOnlyAcceptsEntriesDirectlyUnderResourceRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-dup-trash-\(UUID().uuidString)", isDirectory: true)
        let skillEntry = root.appendingPathComponent("skills/a4", isDirectory: true)
        let otherEntry = root.appendingPathComponent("notes/a4", isDirectory: true)
        try FileManager.default.createDirectory(at: skillEntry, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherEntry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: Never.self) { try PickyDuplicateResourceTrash.validate(skillEntry) }
        for rejected in [root.appendingPathComponent("skills"), otherEntry, FileManager.default.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/")] {
            #expect(throws: PickyDuplicateResourceTrash.TrashError.self) { try PickyDuplicateResourceTrash.validate(rejected) }
        }
        #expect(throws: PickyDuplicateResourceTrash.TrashError.missing(root.appendingPathComponent("skills/gone").path)) {
            try PickyDuplicateResourceTrash.validate(root.appendingPathComponent("skills/gone"))
        }
    }

    @Test @MainActor func partialInstallRefreshesInstalledStatusAndNotesReload() async throws {
        let plugin = PickyCuratedPlugin.cron
        let client = FakeCuratedPluginAgentClient()
        let controller = PickyPluginReloadController(client: client)
        var installed = false
        var changeCount = 0
        let viewModel = PickyCuratedPluginsViewModel(
            plugins: [plugin],
            statusForSource: { _ in installed ? .installed(isPinned: false) : .notInstalled }
        )
        viewModel.onPluginStateChanged = { changeCount += 1 }
        client.sendHandler = { command in
            installed = true
            client.complete(
                requestId: command.id,
                operation: .install,
                source: command.source ?? "",
                ok: false,
                errorMessage: "LaunchAgent did not load",
                packageChanged: true
            )
        }

        viewModel.install(plugin, pluginReloadController: controller)
        try await waitUntil { viewModel.rows.first?.isBusy == false }

        #expect(viewModel.rows.first?.status == .installed(isPinned: false))
        #expect(viewModel.lastError == L10n.t("hub.plugins.error.partial"))
        #expect(changeCount == 1)
    }

    @Test @MainActor func setupSuccessDoesNotMarkPluginReloadPending() async throws {
        let plugin = PickyCuratedPlugin.cron
        let client = FakeCuratedPluginAgentClient()
        let controller = PickyPluginReloadController(client: client)
        var changeCount = 0
        let viewModel = PickyCuratedPluginsViewModel(
            plugins: [plugin],
            statusForSource: { _ in .installed(isPinned: false) }
        )
        viewModel.onPluginStateChanged = { changeCount += 1 }
        client.sendHandler = { command in
            client.complete(
                requestId: command.id,
                operation: .setup,
                source: command.source ?? "",
                ok: true,
                packageChanged: false
            )
        }

        viewModel.setup(plugin, pluginReloadController: controller)
        try await waitUntil { viewModel.rows.first?.isBusy == false }

        #expect(viewModel.lastError == nil)
        #expect(changeCount == 0)
    }

    @Test func updateSendsPackageCommandAndWaitsForDaemonCompletion() async throws {
        let client = FakeCuratedPluginAgentClient()
        var sentCommand: PickyCommandEnvelope?
        client.sendHandler = { command in
            sentCommand = command
            client.complete(requestId: command.id, operation: .update, source: command.source ?? "", ok: true)
        }

        let result = await PickyCuratedPluginInstaller.update(source: source, client: client)

        #expect(sentCommand?.type == .updatePackage)
        #expect(sentCommand?.source == source)
        #expect(throws: Never.self) { try result.get() }
    }

    @Test func removeUsesPinnedSettingsSource() async throws {
        let scratch = try ScratchCuratedPlugin()
        let pinnedSource = "\(source)@1.2.3"
        try scratch.writeSettings(packages: [pinnedSource])
        let client = FakeCuratedPluginAgentClient()
        var sentCommand: PickyCommandEnvelope?
        client.sendHandler = { command in
            sentCommand = command
            client.complete(requestId: command.id, operation: .remove, source: command.source ?? "", ok: true)
        }

        let result = await PickyCuratedPluginInstaller.remove(
            source: source,
            client: client,
            homeURL: scratch.home,
            preferences: PickyPiInstallationPreferences(codingAgentDir: scratch.home.appendingPathComponent(".pi/agent").path)
        )

        #expect(sentCommand?.source == pinnedSource)
        #expect(throws: Never.self) { try result.get() }
    }

    @Test func removeSurfacesDaemonPackageFailure() async {
        let client = FakeCuratedPluginAgentClient()
        client.sendHandler = { command in
            client.complete(
                requestId: command.id,
                operation: .remove,
                source: command.source ?? "",
                ok: false,
                errorMessage: "npm was not found"
            )
        }

        let result = await PickyCuratedPluginInstaller.remove(source: source, client: client)

        if case .failure(.rejected(let rejection)) = result {
            #expect(rejection.detail == "npm was not found")
            #expect(result.failureMessage == L10n.t("hub.plugins.error.failed.remove"))
        } else {
            Issue.record("Expected daemon package failure")
        }
    }

    @Test func installReturnsTimedOutWhenDaemonCompletionNeverArrives() async {
        let client = FakeCuratedPluginAgentClient()

        let result = await PickyCuratedPluginInstaller.install(
            source: source,
            client: client,
            timeoutNanoseconds: 10_000_000
        )

        if case .failure(.timedOut) = result {
            return
        }
        Issue.record("Expected package operation timeout")
    }
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Timed out waiting for curated plugin operation")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private extension Result where Failure == PickyCuratedPluginInstaller.CommandError {
    var failureMessage: String? {
        if case .failure(let error) = self { return error.localizedDescription }
        return nil
    }
}

private final class FakeCuratedPluginAgentClient: PickyAgentClient {
    private let subscriberLock = NSLock()
    private var subscriberContinuations: [UUID: AsyncStream<PickyClientEvent>.Continuation] = [:]
    var events: AsyncStream<PickyClientEvent> {
        AsyncStream { continuation in
            subscriberLock.lock()
            subscriberContinuations[UUID()] = continuation
            subscriberLock.unlock()
        }
    }
    var sendHandler: ((PickyCommandEnvelope) -> Void)?

    func connect() async {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "fake", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        sendHandler?(command)
    }
    func disconnect() {}

    func emitDisconnected() {
        emit(.disconnected)
    }

    func availableUpdates(commandId: String, sources: [String], failed: Bool? = nil) {
        emit(.protocolEvent(PickyEventEnvelope(
            id: "event-package-updates-\(commandId)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: .packageUpdatesAvailable(PickyPackageUpdatesAvailableEvent(
                commandId: commandId,
                sources: sources,
                failed: failed
            ))
        )))
    }

    func conflicts(commandId: String, conflicts: [PickyPackageConflict], failed: Bool? = nil) {
        emit(.protocolEvent(PickyEventEnvelope(
            id: "event-package-conflicts-\(commandId)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: .packageConflicts(PickyPackageConflictsEvent(commandId: commandId, conflicts: conflicts, failed: failed))
        )))
    }

    func complete(
        requestId: String,
        operation: PickyPackageOperation,
        source: String,
        ok: Bool,
        errorMessage: String? = nil,
        errorCode: String? = nil,
        packageChanged: Bool? = nil
    ) {
        emit(.protocolEvent(PickyEventEnvelope(
            id: "event-package-\(requestId)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: .packageOperationCompleted(PickyPackageOperationCompletedEvent(
                requestId: requestId,
                operation: operation,
                source: source,
                ok: ok,
                errorMessage: errorMessage,
                errorCode: errorCode,
                packageChanged: packageChanged
            ))
        )))
    }

    private func emit(_ event: PickyClientEvent) {
        subscriberLock.lock()
        let continuations = Array(subscriberContinuations.values)
        subscriberLock.unlock()
        continuations.forEach { $0.yield(event) }
    }
}

private struct ScratchCuratedPlugin {
    let tmp: URL
    let home: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("picky-curated-plugin-\(UUID().uuidString)", isDirectory: true)
        self.tmp = base
        self.home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func writeSettings(packages: [String], agentDir: URL? = nil) throws {
        let settingsURL = (agentDir ?? home.appendingPathComponent(".pi/agent", isDirectory: true))
            .appendingPathComponent("settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["packages": packages],
            options: [.sortedKeys, .prettyPrinted]
        )
        try data.write(to: settingsURL)
    }

    func writePackageManifest(
        packageName: String,
        manifestName: String? = nil,
        version: String,
        agentDir: URL
    ) throws {
        let packageDirectory = packageName
            .split(separator: "/")
            .reduce(agentDir.appendingPathComponent("npm/node_modules", isDirectory: true)) { directory, component in
                directory.appendingPathComponent(String(component), isDirectory: true)
            }
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["name": manifestName ?? packageName, "version": version],
            options: [.sortedKeys, .prettyPrinted]
        )
        try data.write(to: packageDirectory.appendingPathComponent("package.json", isDirectory: false))
    }
}
