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
                "openAIRealtime": ["apiKey": "another-secret", "voice": "marin"]
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
            runtimeMode: "Pi",
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
        #expect(names.contains("agentd.tool-events.txt"))
        #expect(!names.contains("agentd.stdout.tail.log"))
        #expect(!names.contains("agentd.stdout.log"))
        #expect(names.contains("picky-oslog.txt"))
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
