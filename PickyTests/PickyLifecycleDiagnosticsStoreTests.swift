//
//  PickyLifecycleDiagnosticsStoreTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite
struct PickyLifecycleDiagnosticsStoreTests {
    @Test func cleanRunBecomesCleanPreviousRunOnNextLaunch() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = [
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_010),
            Date(timeIntervalSince1970: 1_700_000_020)
        ]
        let first = PickyLifecycleDiagnosticsStore(
            logsDirectory: root,
            now: { clock.removeFirst() },
            makeRunID: { "first-run" },
            processID: { 101 }
        )
        let firstSnapshot = try #require(first.recordLaunch(appVersion: "1.0", appBuild: "1"))
        _ = first.markCurrentRunClean(reason: .normal)

        let second = PickyLifecycleDiagnosticsStore(
            logsDirectory: root,
            now: { clock.removeFirst() },
            makeRunID: { "second-run" },
            processID: { 202 }
        )
        let secondSnapshot = try #require(second.recordLaunch(appVersion: "1.1", appBuild: "2"))

        #expect(secondSnapshot.current.cleanExit == false)
        #expect(secondSnapshot.previous?.runID == firstSnapshot.current.runID)
        #expect(secondSnapshot.previous?.cleanExit == true)
        #expect(secondSnapshot.previous?.exitReason == .normal)
    }

    @Test func uncleanRunRemainsVisibleAsPreviousRunAfterRelaunch() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PickyLifecycleDiagnosticsStore(
            logsDirectory: root,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeRunID: { "unclean-run" },
            processID: { 101 }
        )
        _ = first.recordLaunch(appVersion: "1.0", appBuild: "1")

        let second = PickyLifecycleDiagnosticsStore(
            logsDirectory: root,
            now: { Date(timeIntervalSince1970: 1_700_000_100) },
            makeRunID: { "next-run" },
            processID: { 202 }
        )
        let snapshot = try #require(second.recordLaunch(appVersion: "1.1", appBuild: "2"))

        #expect(snapshot.previous?.runID == "unclean-run")
        #expect(snapshot.previous?.cleanExit == false)
        #expect(snapshot.previous?.exitedAt == nil)
        #expect(snapshot.previous?.exitReason == nil)
    }

    @Test func boundedSnapshotTextCapsOversizedScalarVersionValues() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickyLifecycleDiagnosticsStore(
            logsDirectory: root,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeRunID: { "large-run" },
            processID: { 101 }
        )
        _ = store.recordLaunch(appVersion: String(repeating: "v", count: 80 * 1024), appBuild: "1")

        let rendered = PickyLifecycleDiagnosticsStore.boundedSnapshotText(
            from: root,
            maxBytes: PickyDiagnosticsBundleBuilder.maximumLifecycleSnapshotBytes
        )

        #expect(rendered.lengthOfBytes(using: .utf8) <= PickyDiagnosticsBundleBuilder.maximumLifecycleSnapshotBytes)
    }

    @Test func updateReasonIsNotOverwrittenByTerminationCallback() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickyLifecycleDiagnosticsStore(
            logsDirectory: root,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeRunID: { "update-run" },
            processID: { 101 }
        )
        _ = store.recordLaunch(appVersion: "1.0", appBuild: "1")
        _ = store.markCurrentRunClean(reason: .update)
        let snapshot = try #require(store.markCurrentRunClean(reason: .normal))

        #expect(snapshot.current.cleanExit == true)
        #expect(snapshot.current.exitReason == .update)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
