//
//  PickyGeneratedReportsPrunerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyGeneratedReportsPrunerTests {
    @Test func deletesMarkdownFilesOlderThanRetention() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let oldFile = directory.appendingPathComponent("old-report.md")
        let recentFile = directory.appendingPathComponent("recent-report.md")
        try "old".write(to: oldFile, atomically: true, encoding: .utf8)
        try "recent".write(to: recentFile, atomically: true, encoding: .utf8)
        try setModificationDate(oldFile, daysBefore: 31, relativeTo: now)
        try setModificationDate(recentFile, daysBefore: 29, relativeTo: now)

        let pruner = PickyGeneratedReportsPruner(
            directory: directory,
            retentionDays: 30,
            now: { now }
        )

        pruner.prune()

        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: recentFile.path))
    }

    @Test func keepsFilesExactlyAtRetentionBoundary() throws {
        // Boundary case: a file modified exactly retentionDays * 86400 seconds
        // ago must be kept so a single clock jitter doesn't sweep
        // borderline reports.
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let boundary = directory.appendingPathComponent("boundary.md")
        try "boundary".write(to: boundary, atomically: true, encoding: .utf8)
        try setModificationDate(boundary, daysBefore: 30, relativeTo: now)

        let pruner = PickyGeneratedReportsPruner(directory: directory, retentionDays: 30, now: { now })

        pruner.prune()

        #expect(FileManager.default.fileExists(atPath: boundary.path))
    }

    @Test func leavesNonMarkdownFilesAndSubdirectoriesAlone() throws {
        // Defense against the pruner accidentally eating user-dropped files
        // (e.g. logs, screenshots a user copied in by hand). Only `.md`
        // entries this app generated are candidates.
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let oldText = directory.appendingPathComponent("old.txt")
        let oldImage = directory.appendingPathComponent("old.png")
        try "old text".write(to: oldText, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: oldImage)
        try setModificationDate(oldText, daysBefore: 365, relativeTo: now)
        try setModificationDate(oldImage, daysBefore: 365, relativeTo: now)

        let nestedDirectory = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nestedOldMarkdown = nestedDirectory.appendingPathComponent("nested-old.md")
        try "nested".write(to: nestedOldMarkdown, atomically: true, encoding: .utf8)
        try setModificationDate(nestedOldMarkdown, daysBefore: 365, relativeTo: now)

        let pruner = PickyGeneratedReportsPruner(directory: directory, retentionDays: 30, now: { now })

        pruner.prune()

        #expect(FileManager.default.fileExists(atPath: oldText.path))
        #expect(FileManager.default.fileExists(atPath: oldImage.path))
        #expect(FileManager.default.fileExists(atPath: nestedOldMarkdown.path))
    }

    @Test func missingDirectoryIsHarmless() {
        // Fresh installs never wrote to GeneratedReports yet — pruning must
        // be a silent no-op, not a launch-time crash.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyGeneratedReportsPrunerTests-missing-\(UUID().uuidString)", isDirectory: true)

        let pruner = PickyGeneratedReportsPruner(directory: directory, retentionDays: 30, now: Date.init)

        pruner.prune()

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyGeneratedReportsPrunerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func setModificationDate(_ url: URL, daysBefore days: Int, relativeTo reference: Date) throws {
        let date = reference.addingTimeInterval(-Double(days) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
