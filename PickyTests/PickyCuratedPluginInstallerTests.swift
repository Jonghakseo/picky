//
//  PickyCuratedPluginInstallerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyCuratedPluginInstallerTests {
    private let source = "npm:@ryan_nookpi/pi-extension-diff-review"

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

        #expect(status == .installed)
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

        #expect(status == .installed)
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
