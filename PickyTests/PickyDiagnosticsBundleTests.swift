//
//  PickyDiagnosticsBundleTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite
struct PickyDiagnosticsBundleTests {
    private func makeFixture(scope: PickyDiagnosticsBundleScope, includeSettings: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-diag-fixture-\(UUID().uuidString)", isDirectory: true)
        let logsDir = root.appendingPathComponent("Logs", isDirectory: true)
        let settingsDir = root.appendingPathComponent("Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        try "stderr fixture".write(to: logsDir.appendingPathComponent("agentd.stderr.log"), atomically: true, encoding: .utf8)
        try "stdout fixture".write(to: logsDir.appendingPathComponent("agentd.stdout.log"), atomically: true, encoding: .utf8)
        if includeSettings {
            let settings: [String: Any] = [
                "azureOpenAIAPIKey": "super-secret-key",
                "defaultCwd": "/tmp/work",
                "voiceProvider": ["apiKey": "another-secret", "voice": "marin"]
            ]
            let data = try JSONSerialization.data(withJSONObject: settings)
            try data.write(to: settingsDir.appendingPathComponent("settings.json"))
        }
        _ = scope
        return root
    }

    private func makeMetadata() -> PickyDiagnosticsBundleMetadata {
        PickyDiagnosticsBundleMetadata(
            appVersion: "0.3.2",
            appBuild: "412",
            osVersion: "15.1.0",
            generatedAt: Date(timeIntervalSince1970: 1_715_500_000)
        )
    }

    @Test func logsOnlyBundleContainsExpectedFiles() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "fake oslog entries" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let names = try inspectZipEntryNames(at: bundle.zipURL)
        #expect(names.contains("agentd.stderr.tail.log"))
        #expect(names.contains("agentd.port-occupants.txt"))
        #expect(names.contains("agentd.tool-events.txt"))
        #expect(names.contains("agentd.session-identity.txt"))
        #expect(names.contains("agentd.lifecycle-events.txt"))
        #expect(names.contains("watchdog.summary.txt"))
        #expect(names.contains("watchdog.samples.txt"))
        #expect(!names.contains("agentd.stdout.tail.log"))
        #expect(!names.contains("agentd.stdout.log"))
        #expect(names.contains("picky-oslog.txt"))
        #expect(names.contains("picky-lifecycle.json"))
        #expect(names.contains("picky-ips-manifest.txt"))
        #expect(names.contains("picky-ips-excerpts.txt"))
        #expect(names.contains("metadata.txt"))
        #expect(!names.contains("settings.sanitized.json"))
    }

    @Test func fullBundleAddsSanitizedSettings() throws {
        let fixture = try makeFixture(scope: .full)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .full,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "fake oslog entries" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let names = try inspectZipEntryNames(at: bundle.zipURL)
        #expect(names.contains("settings.sanitized.json"))
    }

    @Test func filenameIncludesScopeAndGeneratedAtTimestamp() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }
        #expect(bundle.filename.hasPrefix("picky-diagnostics-logs-"))
        #expect(bundle.filename.hasSuffix(".zip"))
    }

    @Test func fullFilenameIncludesFullScope() throws {
        let fixture = try makeFixture(scope: .full)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .full,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }
        #expect(bundle.filename.hasPrefix("picky-diagnostics-full-"))
        #expect(bundle.filename.hasSuffix(".zip"))
    }

    @Test func stderrLogIsCappedToTail() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let logsDir = fixture.appendingPathComponent("Logs", isDirectory: true)
        let longLog = String(repeating: "a", count: 20) + "TAIL"
        try longLog.write(to: logsDir.appendingPathComponent("agentd.stderr.log"), atomically: true, encoding: .utf8)

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            maxLogBytes: 8,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let stderrTail = try extractZipEntryText(named: "agentd.stderr.tail.log", from: bundle.zipURL)
        #expect(stderrTail.contains("last 8 bytes of 24 bytes"))
        #expect(stderrTail.hasSuffix("aaaaTAIL"))
        #expect(!stderrTail.contains(String(repeating: "a", count: 12)))
    }

    @Test func stdoutRawContentIsNotBundledButToolNamesAreSummarized() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let logsDir = fixture.appendingPathComponent("Logs", isDirectory: true)
        let stdout = """
        2026-05-12T08:00:00.000Z picky-agentd tool activity sessionId=\"secret-session\" tool=\"bash\" status=running previewChars=999
        user chat should never appear
        command=\"rm -rf sensitive\"
        result=\"private output\"
        2026-05-12T08:00:01.000Z picky-agentd tool activity sessionId=\"secret-session\" tool=\"read\" status=succeeded previewChars=123
        """
        try stdout.write(to: logsDir.appendingPathComponent("agentd.stdout.log"), atomically: true, encoding: .utf8)

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let toolSummary = try extractZipEntryText(named: "agentd.tool-events.txt", from: bundle.zipURL)
        #expect(toolSummary.contains("tool=bash status=running"))
        #expect(toolSummary.contains("tool=read status=succeeded"))
        #expect(!toolSummary.contains("secret-session"))
        #expect(!toolSummary.contains("user chat should never appear"))
        #expect(!toolSummary.contains("rm -rf sensitive"))
        #expect(!toolSummary.contains("private output"))
    }

    @Test func lifecycleExtractIncludesOnlyAllowlistedScalarEvidence() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let logsDir = fixture.appendingPathComponent("Logs", isDirectory: true)
        let stdout = """
        2026-07-22T01:00:00.000Z picky-agentd lifecycle event="followUpRequested" sessionId="private-session" sessionStatus="completed" isStreaming=true isCompacting=false queuedFollowUpCount=1 pendingDeliveryCount=1 textChars=42 source="voice-follow-up" prompt="private user request" path="/Users/jane/private"
        2026-07-22T01:00:01.000Z picky-agentd lifecycle event="followUpQueueStalled" sessionId="private-session" sessionStatus="running" isStreaming=true ageMs=30000 queuedFollowUpCount=1 error="private error"
        2026-07-22T01:00:01.500Z picky-agentd lifecycle event="manualCompactStarted" sessionId="private-session" sessionStatus="completed" wasStreaming=false instructionChars=17 outcome="resolved"
        2026-07-22T01:00:02.000Z picky-agentd lifecycle event="unapprovedEvent" text="must not be included"
        ordinary stdout with secret transcript
        """
        try stdout.write(to: logsDir.appendingPathComponent("agentd.stdout.log"), atomically: true, encoding: .utf8)

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let lifecycle = try extractZipEntryText(named: "agentd.lifecycle-events.txt", from: bundle.zipURL)
        #expect(lifecycle.contains("timestamp=2026-07-22T01:00:00.000Z event=followUpRequested sessionStatus=completed"))
        #expect(lifecycle.contains("timestamp=2026-07-22T01:00:01.000Z event=followUpQueueStalled sessionStatus=running"))
        #expect(lifecycle.contains("textChars=42"))
        #expect(lifecycle.contains("source=voice-follow-up"))
        #expect(lifecycle.contains("ageMs=30000"))
        #expect(lifecycle.contains("wasStreaming=false"))
        #expect(lifecycle.contains("instructionChars=17"))
        #expect(!lifecycle.contains("private-session"))
        #expect(!lifecycle.contains("private user request"))
        #expect(!lifecycle.contains("/Users/jane/private"))
        #expect(!lifecycle.contains("private error"))
        #expect(!lifecycle.contains("unapprovedEvent"))
        #expect(!lifecycle.contains("secret transcript"))
    }

    @Test func stderrTailFallsBackToPlaceholderWhenSourceIsMissing() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.removeItem(at: fixture
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("agentd.stderr.log"))

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let names = try inspectZipEntryNames(at: bundle.zipURL)
        #expect(names.contains("agentd.stderr.tail.log"))
        let stderrTail = try extractZipEntryText(named: "agentd.stderr.tail.log", from: bundle.zipURL)
        #expect(stderrTail.contains("absent"))
        #expect(stderrTail.contains("agentd.stderr.log"))
    }

    @Test func stderrTailRecordsEmptyPlaceholderWhenSourceIsZeroBytes() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stderrPath = fixture
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("agentd.stderr.log")
        try Data().write(to: stderrPath)

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let stderrTail = try extractZipEntryText(named: "agentd.stderr.tail.log", from: bundle.zipURL)
        #expect(stderrTail.contains("present but empty"))
    }

    @Test func daemonStatusSnapshotIsStagedWhenPresent() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let statusPayload = #"{"state":"running","pid":42,"role":"primary","port":17631,"attempts":0,"lastUpdatedAt":"2026-05-13T19:44:49Z"}"#
        try statusPayload.write(
            to: fixture
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("agentd.status.json"),
            atomically: true,
            encoding: .utf8
        )

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let names = try inspectZipEntryNames(at: bundle.zipURL)
        #expect(names.contains("agentd.status.json"))
        let staged = try extractZipEntryText(named: "agentd.status.json", from: bundle.zipURL)
        #expect(staged.contains("\"state\":\"running\""))
        #expect(staged.contains("\"pid\":42"))
    }

    @Test func daemonStatusSnapshotPlaceholderWhenAbsent() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let names = try inspectZipEntryNames(at: bundle.zipURL)
        #expect(names.contains("agentd.status.json"))
        let staged = try extractZipEntryText(named: "agentd.status.json", from: bundle.zipURL)
        #expect(staged.contains("absent"))
    }

    @Test func roleSpecificDaemonStatusSnapshotsAreBundled() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let logsDir = fixture.appendingPathComponent("Logs", isDirectory: true)
        try #"{"state":"running","role":"primary","port":17631,"attempts":0,"lastUpdatedAt":"2026-05-13T19:44:49Z"}"#.write(
            to: logsDir.appendingPathComponent("agentd.status.primary.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"state":"failedToStart","role":"child(session…)","port":0,"attempts":0,"lastUpdatedAt":"2026-05-13T19:45:49Z"}"#.write(
            to: logsDir.appendingPathComponent("agentd.status.child-session-123.json"),
            atomically: true,
            encoding: .utf8
        )

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let names = try inspectZipEntryNames(at: bundle.zipURL)
        #expect(names.contains("agentd.status.primary.json"))
        #expect(names.contains("agentd.status.child-session-123.json"))
        #expect(names.contains("agentd.status.json"))
    }

    @Test func nodePreflightSnapshotIsBundledWhenPresent() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let logsDir = fixture.appendingPathComponent("Logs", isDirectory: true)
        try #"{"status":"timedOut","nodePath":"/Users/jane/.local/bin/node","requiredNodeVersion":"22.19.0"}"#.write(
            to: logsDir.appendingPathComponent("agentd.node-preflight.json"),
            atomically: true,
            encoding: .utf8
        )

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let staged = try extractZipEntryText(named: "agentd.node-preflight.json", from: bundle.zipURL)
        #expect(staged.contains("timedOut"))
        #expect(staged.contains("/Users/<redacted-user>/.local/bin/node"))
    }

    @Test func watchdogDiagnosticsSummarizeStallsAndRedactBoundedSamples() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let logsDir = fixture.appendingPathComponent("Logs", isDirectory: true)
        let sampleText = """
        Path: /Users/jane/Library/Application Support/Picky/Picky.app
        apiKey=supersecretvalue
        Thread 0 Crashed:: Dispatch queue: com.apple.main-thread
        0   Picky  PickyBubbleMarkdownContentView.measuredSize
        \(String(repeating: "sample frame\n", count: 40))
        SHOULD_NOT_APPEAR_AFTER_CAP
        """
        let sampleURL = logsDir.appendingPathComponent("spin-2026-06-22T01-54-50.txt")
        try sampleText.write(to: sampleURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_781_000_000)],
            ofItemAtPath: sampleURL.path
        )

        let oslog = """
        2026-06-22T01:54:40Z notice [com.jonghakseo.picky] main thread soft stall detected ageMs=2310 thresholdMs=2000
        2026-06-22T01:54:42Z notice [com.jonghakseo.picky] main thread soft stall recovered ageMs=2450
        user chat should never appear in watchdog summary
        """
        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            maxWatchdogSampleBytes: 180,
            oslogProvider: { oslog }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let summary = try extractZipEntryText(named: "watchdog.summary.txt", from: bundle.zipURL)
        #expect(summary.contains("softStallDetectedCount=1"))
        #expect(summary.contains("softStallRecoveredCount=1"))
        #expect(summary.contains("maxSoftStallAgeMs=2310"))
        #expect(summary.contains("maxSoftStallRecoveryAgeMs=2450"))
        #expect(summary.contains("maxSoftStallThresholdMs=2000"))
        #expect(summary.contains("spinSampleFileCount=1"))
        #expect(!summary.contains("user chat should never appear"))

        let samples = try extractZipEntryText(named: "watchdog.samples.txt", from: bundle.zipURL)
        #expect(samples.contains("spin-2026-06-22T01-54-50.txt"))
        #expect(samples.contains("truncated=true"))
        #expect(!samples.contains("/Users/jane"))
        #expect(samples.contains("/Users/<redacted-user>"))
        #expect(!samples.contains("supersecretvalue"))
        #expect(samples.contains("<redacted>"))
        #expect(!samples.contains("SHOULD_NOT_APPEAR_AFTER_CAP"))
    }

    @Test func portOccupancyDiagnosticsProbePortsFromEADDRINUSEStderr() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let logsDir = fixture.appendingPathComponent("Logs", isDirectory: true)
        try "Error: listen EADDRINUSE: address already in use 127.0.0.1:17631\n  port: 17631".write(
            to: logsDir.appendingPathComponent("agentd.stderr.log"),
            atomically: true,
            encoding: .utf8
        )

        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            oslogProvider: { "" },
            portOccupancyProvider: { ports in "ports=\(ports.map(String.init).joined(separator: ","))\nnode 123 jane" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let portDiagnostics = try extractZipEntryText(named: "agentd.port-occupants.txt", from: bundle.zipURL)
        #expect(portDiagnostics.contains("ports=17631"))
        #expect(portDiagnostics.contains("node 123 jane"))
    }

    @Test func crashDiagnosticsConstantsForm704KiBAggregateBudget() {
        #expect(PickyDiagnosticsBundleBuilder.maximumPreviousProcessOSLogBytes == 256 * 1024)
        #expect(PickyDiagnosticsBundleBuilder.maximumIPSExcerptBytes == 384 * 1024)
        #expect(PickyDiagnosticsBundleBuilder.maximumLifecycleSnapshotBytes + PickyDiagnosticsBundleBuilder.maximumIPSManifestBytes == PickyDiagnosticsBundleBuilder.maximumLifecycleAndManifestBytes)
        #expect(PickyDiagnosticsBundleBuilder.maximumPreviousProcessOSLogBytes + PickyDiagnosticsBundleBuilder.maximumIPSExcerptBytes + PickyDiagnosticsBundleBuilder.maximumLifecycleAndManifestBytes == 704 * 1024)
    }

    @Test func metadataIncludesScopeAndTailLimit() throws {
        let fixture = try makeFixture(scope: .logsOnly)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let bundle = try PickyDiagnosticsBundleBuilder.build(
            scope: .logsOnly,
            metadata: makeMetadata(),
            appSupportRoot: fixture,
            maxLogBytes: 123,
            oslogProvider: { "" }
        )
        defer { try? FileManager.default.removeItem(at: bundle.zipURL.deletingLastPathComponent()) }

        let metadata = try extractZipEntryText(named: "metadata.txt", from: bundle.zipURL)
        #expect(metadata.contains("Diagnostics scope:  Logs only"))
        #expect(metadata.contains("Log tail limit:     123 bytes for included stderr tail"))
        #expect(metadata.contains("User chat, tool arguments, and tool results are excluded"))
    }

    /// Lightweight zip inspection — calls /usr/bin/unzip to list entries so we
    /// don't pull in a zip parser just for tests. macOS ships unzip everywhere
    /// our test platform runs.
    private func inspectZipEntryNames(at url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z", "-1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        // Output lines include the bundle's top-level directory prefix, e.g.
        // "picky-diagnostics-logs-20260512-014640/agentd.stderr.tail.log". Trim the prefix
        // so callers can match on plain filenames.
        return raw
            .split(separator: "\n")
            .map { String($0) }
            .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            .filter { !$0.isEmpty }
    }

    private func extractZipEntryText(named entryName: String, from url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "*/\(entryName)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
