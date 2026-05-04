//
//  PickySettingsPolishTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickySettingsPolishTests {
    @Test func settingsLoadDefaultsAppearanceToDarkWhenLegacyFileLacksField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Settings", isDirectory: true), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: url)
        let store = PickySettingsStore(url: url)

        #expect(store.load().appearance == .dark)
    }

    @Test func fontScalesClampingRoundsAndBoundsValuesIntoTheSupportedRange() throws {
        #expect(PickyFontScales.clamped(1.0) == 1.0)
        #expect(PickyFontScales.clamped(0.0) == PickyFontScales.minimum)
        #expect(PickyFontScales.clamped(99) == PickyFontScales.maximum)
        // 0.1 step taps should accumulate exactly because clamped() rounds to one decimal.
        var value = 1.0
        for _ in 0..<3 { value = PickyFontScales.clamped(value + 0.1) }
        #expect(value == 1.3)
    }

    @Test func settingsLoadDefaultsFontScalesToOneWhenLegacyFileLacksField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Settings", isDirectory: true), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: url)
        let store = PickySettingsStore(url: url)

        let loaded = store.load().fontScales
        #expect(loaded.markdownReport == 1.0)
        #expect(loaded.terminal == 1.0)
    }

    @Test func settingsRoundTripPreservesAndClampsFontScales() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.fontScales = PickyFontScales(markdownReport: 1.4, terminal: 1.8)
        try store.save(settings)

        let reloaded = store.load().fontScales
        #expect(reloaded.markdownReport == 1.4)
        #expect(reloaded.terminal == 1.8)

        // Out-of-range values stored by an older or corrupted client get clamped on load
        // so the UI never starts in a 0.1× or 10× broken state.
        let url = root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        let raw = try String(contentsOf: url)
        let mutated = raw.replacingOccurrences(of: "\"markdownReport\" : 1.4", with: "\"markdownReport\" : 99")
        try mutated.data(using: .utf8)!.write(to: url)
        let clamped = store.load().fontScales
        #expect(clamped.markdownReport == PickyFontScales.maximum)
        #expect(clamped.terminal == 1.8)
    }

    @Test func settingsRoundTripPreservesAppearanceMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var settings = PickySettings.defaults(appSupportRoot: root)
        settings.defaultCwd = project.path
        settings.worktreeParent = project.path
        settings.appearance = .light

        try store.save(settings)
        #expect(store.load().appearance == .light)
    }

    @Test func appearanceStoreToggleAndPersistsThroughSettingsFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let settingsStore = PickySettingsStore(appSupportRoot: root)
        var seed = PickySettings.defaults(appSupportRoot: root)
        seed.defaultCwd = project.path
        seed.worktreeParent = project.path
        try settingsStore.save(seed)

        let appearance = await PickyAppearanceStore(settingsStore: settingsStore)
        await #expect(appearance.mode == .dark)

        await appearance.toggle()
        await #expect(appearance.mode == .light)

        let reloaded = settingsStore.load()
        #expect(reloaded.appearance == .light)

        let rehydrated = await PickyAppearanceStore(settingsStore: settingsStore)
        await #expect(rehydrated.mode == .light)
    }

    @Test func settingsPersistReloadAndRejectInvalidCwd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let worktrees = root.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        let settings = PickySettings(
            defaultCwd: project.path,
            worktreeParent: worktrees.path,
            preferredToolVisibility: "show tool activity",
            readOnlyInvestigationPreference: true,
            daemonPath: "/tmp/agentd",
            logPath: root.appendingPathComponent("Logs").path
        )

        try store.save(settings)
        #expect(store.load() == settings)

        var invalid = settings
        invalid.defaultCwd = root.appendingPathComponent("missing").path
        #expect(throws: PickySettingsValidationError.invalidDefaultCwd(invalid.defaultCwd)) {
            try store.save(invalid)
        }
    }

    @Test func settingsNormalizeTildePathsBeforePersisting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-settings-\(UUID().uuidString)", isDirectory: true)
        let store = PickySettingsStore(appSupportRoot: root)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let settings = PickySettings(
            defaultCwd: "~",
            worktreeParent: "~",
            preferredToolVisibility: "show tool activity",
            readOnlyInvestigationPreference: true,
            daemonPath: "/tmp/agentd",
            logPath: root.appendingPathComponent("Logs").path
        )

        try store.save(settings)

        #expect(store.load().defaultCwd == home)
        #expect(store.load().worktreeParent == home)
    }

    @Test func diffPreviewGroupsFilesAndTruncatesSafely() {
        let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        +aaaaaa
        diff --git a/Sources/B.swift b/Sources/B.swift
        +bbbbbb
        """

        let preview = PickyDiffPreviewBuilder(maxCharactersPerFile: 20).build(from: diff)

        #expect(preview.files.map(\.path) == ["Sources/A.swift", "Sources/B.swift"])
        #expect(preview.files.allSatisfy { $0.isTruncated })
        #expect(preview.files.first?.text.contains("[diff truncated by Picky]") == true)
    }

    @Test func archiveSearchUsesTitleCwdStatusPrAndSummaryWithoutFabrication() {
        let pr = PickyArtifact(id: "pr-1", kind: "pr", title: "PR", path: nil, url: URL(string: "https://github.com/acme/repo/pull/77")!, updatedAt: Date(timeIntervalSince1970: 1))
        let running = session(id: "running", title: "Investigate checkout", status: .running, cwd: "/tmp/shop", summary: "looking", artifacts: [])
        let completed = session(id: "done", title: "Ship fix", status: .completed, cwd: "/tmp/picky", summary: "final answer", artifacts: [pr])
        var archive = PickySessionArchive(active: [running, completed])

        archive.archive(sessionID: "done")

        #expect(archive.active.map(\.id) == ["running"])
        #expect(archive.archived.map(\.id) == ["done"])
        #expect(archive.search("pull/77").map(\.id) == ["done"])
        #expect(archive.search("running").map(\.id) == ["running"])
        #expect(archive.search("made up verification").isEmpty)
    }

    @MainActor
    @Test func viewModelArchivesAndSearchesSessions() async throws {
        let client = FakePolishClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: sessionUpdatedJSON(id: "archive-me", title: "Archive Me", status: "completed", summary: "final summary"))))
        try await Task.sleep(nanoseconds: 200_000_000)

        viewModel.archive(sessionID: "archive-me")

        #expect(viewModel.sessions.isEmpty)
        #expect(viewModel.archivedSessions.map(\.id) == ["archive-me"])
        #expect(viewModel.searchSessions(query: "final").map(\.id) == ["archive-me"])
    }

    @Test func friendlyMissingPiErrorsAreActionable() {
        let checker = PickyRuntimeDependencyChecker(piSDKPath: "/tmp/picky-missing-sdk-\(UUID().uuidString)", pathEnvironment: "/tmp")

        #expect(checker.missingPiSDKErrorIfNeeded()?.localizedDescription.contains("Pi SDK") == true)
        #expect(checker.missingPiExecutableErrorIfNeeded() == .missingPiExecutable)
        #expect(PickyFriendlyRuntimeError.permissionDenied("Screen Recording").localizedDescription.contains("reduced context"))
    }

    private func session(id: String, title: String, status: PickySessionStatus, cwd: String, summary: String, artifacts: [PickyArtifact]) -> PickyAgentSession {
        PickyAgentSession(
            id: id,
            title: title,
            status: status,
            cwd: cwd,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            lastSummary: summary,
            logs: [],
            tools: [],
            artifacts: artifacts,
            changedFiles: [],
            pendingExtensionUiRequest: nil
        )
    }
}

private final class FakePolishClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt { PickyAgentSubmissionReceipt(sessionID: "unused", message: "unused") }
    func send(_ command: PickyCommandEnvelope) async throws {}
    func disconnect() { continuation.yield(.disconnected) }
    func emit(_ event: PickyClientEvent) { continuation.yield(event) }
}

private func sessionUpdatedJSON(id: String, title: String, status: String, summary: String) -> String {
    """
    {"id":"event-\(id)-\(status)","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionUpdated","session":{"id":"\(id)","title":"\(title)","status":"\(status)","cwd":"/tmp/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"\(summary)","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
    """
}

private extension PickyEventEnvelope {
    static func fixture(eventJSON: String) -> PickyEventEnvelope {
        try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(eventJSON.utf8))
    }
}
