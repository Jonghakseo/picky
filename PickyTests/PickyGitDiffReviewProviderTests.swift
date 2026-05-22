//
//  PickyGitDiffReviewProviderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyGitDiffReviewProviderTests {
    @Test func loadCapturesBranchAndWorktreeSnapshotChanges() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try "base\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try runGit(["checkout", "-b", "feature/review"] , cwd: directory)
        try "branch\n".write(to: directory.appendingPathComponent("branch.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "branch.txt"], cwd: directory)
        try runGit(["commit", "-m", "feature change"], cwd: directory)

        try "base\nworktree\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "new\nfile\n".write(to: directory.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try "ignored minified\n".write(to: directory.appendingPathComponent("bundle.min.js"), atomically: true, encoding: .utf8)

        let data = try await PickyGitDiffReviewProvider().load(cwd: directory.path)

        #expect(URL(fileURLWithPath: data.repoRoot).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
        #expect(data.repositoryName == directory.lastPathComponent)
        #expect(data.branchName == "feature/review")
        #expect(data.repositoryHasHead == true)
        #expect(data.branchBaseRef == "main")
        #expect(data.branchMergeBaseSha?.isEmpty == false)

        let branch = try #require(data.scopeData(.branch))
        #expect(branch.baseLabel == "main")
        #expect(branch.targetLabel == "Working tree")
        #expect(branch.files.map(\.displayPath) == ["branch.txt", "tracked.txt", "untracked.txt"])
        #expect(branch.insertions == 4)
        #expect(branch.deletions == 0)

        let worktree = try #require(data.scopeData(.worktree))
        #expect(worktree.baseLabel == "HEAD")
        #expect(worktree.targetLabel == "Working tree")
        #expect(worktree.files.map(\.displayPath) == ["tracked.txt", "untracked.txt"])
        #expect(worktree.insertions == 3)
        #expect(worktree.deletions == 0)

        let diff = try await PickyGitDiffReviewProvider().loadDiff(
            cwd: directory.path,
            scope: .worktree,
            fileID: try #require(worktree.files.first { $0.displayPath == "untracked.txt" }).id
        )
        #expect(diff.contains("diff --git"))
        #expect(diff.contains("+new"))
        #expect(diff.contains("+file"))
    }

    @Test func loadUsesEmptyTreeForRepositoryWithoutHead() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try "hello\nworld\n".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let data = try await PickyGitDiffReviewProvider().load(cwd: directory.path)

        #expect(data.repositoryHasHead == false)
        #expect(data.branchName == "main")
        let branch = try #require(data.scopeData(.branch))
        let worktree = try #require(data.scopeData(.worktree))
        #expect(branch.baseLabel == "Empty tree")
        #expect(worktree.baseLabel == "Empty tree")
        #expect(branch.files.map(\.displayPath) == ["notes.txt"])
        #expect(worktree.files.map(\.displayPath) == ["notes.txt"])
        #expect(branch.insertions == 2)
        #expect(worktree.insertions == 2)
    }

    @Test func loadPreservesRenameStatsFromGitNumstatBraceFormat() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "one\ntwo\n".write(to: directory.appendingPathComponent("Sources/OldName.swift"), atomically: true, encoding: .utf8)
        try runGit(["add", "Sources/OldName.swift"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try runGit(["mv", "Sources/OldName.swift", "Sources/NewName.swift"], cwd: directory)
        try "one\ntwo\nthree\n".write(to: directory.appendingPathComponent("Sources/NewName.swift"), atomically: true, encoding: .utf8)

        let data = try await PickyGitDiffReviewProvider().load(cwd: directory.path)
        let worktree = try #require(data.scopeData(.worktree))
        let renamed = try #require(worktree.files.first)

        #expect(renamed.status == .renamed)
        #expect(renamed.oldPath == "Sources/OldName.swift")
        #expect(renamed.newPath == "Sources/NewName.swift")
        #expect(renamed.displayPath == "Sources/OldName.swift → Sources/NewName.swift")
        #expect(renamed.insertions == 1)
        #expect(renamed.deletions == 0)
    }

    @Test func loadDiffPreservesRenameMetadataAndEditHunk() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let original = (0..<20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let modified = (0..<20).map { $0 == 10 ? "line 10 changed" : "line \($0)" }.joined(separator: "\n") + "\n"
        try original.write(to: directory.appendingPathComponent("Sources/OldName.swift"), atomically: true, encoding: .utf8)
        try runGit(["add", "Sources/OldName.swift"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try runGit(["mv", "Sources/OldName.swift", "Sources/NewName.swift"], cwd: directory)
        try modified.write(to: directory.appendingPathComponent("Sources/NewName.swift"), atomically: true, encoding: .utf8)

        let data = try await PickyGitDiffReviewProvider().load(cwd: directory.path)
        let worktree = try #require(data.scopeData(.worktree))
        let renamed = try #require(worktree.files.first { $0.status == .renamed })

        let diff = try await PickyGitDiffReviewProvider().loadDiff(cwd: directory.path, scope: .worktree, fileID: renamed.id)

        #expect(diff.contains("rename from Sources/OldName.swift"))
        #expect(diff.contains("rename to Sources/NewName.swift"))
        #expect(diff.contains("-line 10"))
        #expect(diff.contains("+line 10 changed"))
    }

    @Test func loadDiffReturnsLargeUnifiedDiffWithoutPipeDeadlock() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        let original = (0..<1_200).map { "original line \($0)" }.joined(separator: "\n") + "\n"
        let modified = (0..<1_200).map { "modified line \($0) with enough content to exceed the default pipe buffer" }.joined(separator: "\n") + "\n"
        try original.write(to: directory.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "large.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try modified.write(to: directory.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)

        let data = try await PickyGitDiffReviewProvider().load(cwd: directory.path)
        let worktree = try #require(data.scopeData(.worktree))
        let file = try #require(worktree.files.first { $0.displayPath == "large.txt" })

        let diff = try await PickyGitDiffReviewProvider().loadDiff(cwd: directory.path, scope: .worktree, fileID: file.id)

        #expect(diff.utf8.count > 65_536)
        #expect(diff.contains("-original line 0"))
        #expect(diff.contains("+modified line 1199"))
    }

    @Test func sessionDiffUsesLoadedSnapshotInsteadOfReloadingWorkingTree() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try "base\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try "base\nfirst snapshot\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)

        let session = PickyGitDiffReviewProvider().makeSession()
        let data = try await session.load(cwd: directory.path)
        let worktree = try #require(data.scopeData(.worktree))
        let file = try #require(worktree.files.first { $0.displayPath == "tracked.txt" })

        try "base\nchanged after load\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let diff = try await session.loadDiff(scope: .worktree, fileID: file.id)
        await session.close()

        #expect(diff.contains("+first snapshot"))
        #expect(!diff.contains("+changed after load"))
    }

    @Test func loadThrowsOutsideGitRepository() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: PickyGitDiffReviewProviderError.notGitRepository) {
            _ = try await PickyGitDiffReviewProvider().load(cwd: directory.path)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-git-diff-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func initializeRepository(at directory: URL) throws {
        try runGit(["init", "-b", "main"], cwd: directory)
        try runGit(["config", "user.email", "picky@example.com"], cwd: directory)
        try runGit(["config", "user.name", "Picky Tests"], cwd: directory)
        try runGit(["config", "commit.gpgsign", "false"], cwd: directory)
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
