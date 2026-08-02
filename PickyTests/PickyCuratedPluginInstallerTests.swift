//
//  PickyCuratedPluginInstallerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyCuratedPluginInstallerTests {
    private let source = "npm:@ryan_nookpi/pi-extension-diff-review"

    @Test func curatedDefaultsIncludeSubagentWithExpectedSource() {
        let subagent = PickyCuratedPlugin.curatedDefaults.first { $0.id == "subagent" }

        #expect(subagent?.source == "npm:@ryan_nookpi/pi-extension-subagent")
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

        if case .failure(.failed(let message)) = result {
            #expect(message == "npm was not found")
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
}

private final class FakeCuratedPluginAgentClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    var sendHandler: ((PickyCommandEnvelope) -> Void)?

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "fake", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        sendHandler?(command)
    }
    func disconnect() {}

    func emitDisconnected() {
        continuation.yield(.disconnected)
    }

    func availableUpdates(commandId: String, sources: [String]) {
        continuation.yield(.protocolEvent(PickyEventEnvelope(
            id: "event-package-updates-\(commandId)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: .packageUpdatesAvailable(PickyPackageUpdatesAvailableEvent(
                commandId: commandId,
                sources: sources
            ))
        )))
    }

    func complete(
        requestId: String,
        operation: PickyPackageOperation,
        source: String,
        ok: Bool,
        errorMessage: String? = nil
    ) {
        continuation.yield(.protocolEvent(PickyEventEnvelope(
            id: "event-package-\(requestId)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: .packageOperationCompleted(PickyPackageOperationCompletedEvent(
                requestId: requestId,
                operation: operation,
                source: source,
                ok: ok,
                errorMessage: errorMessage
            ))
        )))
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
}
