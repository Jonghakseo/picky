//
//  PickyGitRepositoryStatusTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyGitRepositoryStatusTests {
    @Test func parsesDiffAndCommitPositionStats() {
        let diff = PickyGitRepositoryStatus.parseNumstat("2\t1\tSources/App.swift\n-\t-\tAssets/logo.png\n3\t0\tREADME.md\n")
        #expect(diff.insertions == 5)
        #expect(diff.deletions == 1)

        let position = PickyGitRepositoryStatus.parseAheadBehind("4\t2\n")
        #expect(position.ahead == 2)
        #expect(position.behind == 4)
    }

    @Test func loadReturnsNilOutsideGitRepository() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let status = await PickyGitRepositoryStatus.load(cwd: directory.path)

        #expect(status == nil)
    }

    @Test func loadReadsRepositoryBranchDirtyFlagAndDiffStats() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try runGit(["init", "-b", "main"], cwd: directory)
        try runGit(["config", "user.email", "picky@example.com"], cwd: directory)
        try runGit(["config", "user.name", "Picky Tests"], cwd: directory)
        try runGit(["config", "commit.gpgsign", "false"], cwd: directory)
        let fileURL = directory.appendingPathComponent("notes.txt")
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "notes.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try "one\nthree\nfour\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let status = await PickyGitRepositoryStatus.load(cwd: directory.path)

        #expect(status?.repositoryName == directory.lastPathComponent)
        #expect(status?.branchName == "main")
        #expect(status?.hasUncommittedChanges == true)
        #expect(status?.repositoryDisplayName == "\(directory.lastPathComponent)*")
        #expect(status?.insertions == 2)
        #expect(status?.deletions == 1)
        #expect(status?.aheadCount == 0)
        #expect(status?.behindCount == 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-git-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = cwd
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
