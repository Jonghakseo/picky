//
//  PickyGitDiffReviewProviderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite(.serialized)
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

    @Test func loadIncludesWorkingTreePseudoCommitForRepositoryWithoutHead() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try "hello\nworld\n".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let session = PickyGitDiffReviewProvider().makeSession()
        let data = try await session.load(cwd: directory.path)
        let files = try await session.loadCommitFiles(commitSha: "__pi_working_tree__")
        await session.close()

        #expect(data.repositoryHasHead == false)
        #expect(data.commits.first?.sha == "__pi_working_tree__")
        #expect(data.commits.first?.kind == .workingTree)
        #expect(files.map(\.displayPath) == ["notes.txt"])
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

    @Test func loadIncludesBranchRangeCommitsAndWorkingTreePseudoCommit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try "base\n".write(to: directory.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "base.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try runGit(["checkout", "-b", "feature/commits"], cwd: directory)
        try "feature\n".write(to: directory.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "feature.txt"], cwd: directory)
        try runGit(["commit", "-m", "feature commit"], cwd: directory)
        try "dirty\n".write(to: directory.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)

        let data = try await PickyGitDiffReviewProvider().load(cwd: directory.path)

        #expect(data.commits.first?.sha == "__pi_working_tree__")
        #expect(data.commits.first?.shortSha == "WT")
        #expect(data.commits.first?.subject == "Uncommitted changes")
        #expect(data.commits.first?.kind == .workingTree)
        #expect(data.commits.contains { $0.subject == "feature commit" && $0.kind == .commit })
    }

    @Test func sessionLoadsCommitFilesAndDiffForSelectedCommit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try "base\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try "base\ncommit\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: directory.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt", "added.txt"], cwd: directory)
        try runGit(["commit", "-m", "second commit"], cwd: directory)
        let commitSha = try gitOutput(["rev-parse", "HEAD"], cwd: directory)

        let session = PickyGitDiffReviewProvider().makeSession()
        _ = try await session.load(cwd: directory.path)
        let files = try await session.loadCommitFiles(commitSha: commitSha)
        let tracked = try #require(files.first { $0.displayPath == "tracked.txt" })
        let added = try #require(files.first { $0.displayPath == "added.txt" })
        let diff = try await session.loadCommitDiff(commitSha: commitSha, fileID: tracked.id)
        await session.close()

        #expect(files.map(\.displayPath) == ["added.txt", "tracked.txt"])
        #expect(added.status == .added)
        #expect(added.insertions == 1)
        #expect(tracked.status == .modified)
        #expect(tracked.insertions == 1)
        #expect(diff.contains("diff --git a/tracked.txt b/tracked.txt"))
        #expect(diff.contains("+commit"))
        #expect(!diff.contains("added.txt"))
    }

    @Test func sessionLoadsWorkingTreePseudoCommitFromSnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try "base\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try "base\ndirty snapshot\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)

        let session = PickyGitDiffReviewProvider().makeSession()
        let data = try await session.load(cwd: directory.path)
        try "base\nchanged after load\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let files = try await session.loadCommitFiles(commitSha: "__pi_working_tree__")
        let file = try #require(files.first { $0.displayPath == "tracked.txt" })
        let diff = try await session.loadCommitDiff(commitSha: "__pi_working_tree__", fileID: file.id)
        await session.close()

        #expect(data.commits.first?.kind == .workingTree)
        #expect(diff.contains("+dirty snapshot"))
        #expect(!diff.contains("+changed after load"))
    }

    @Test func sessionLoadsRootCommitFilesAndDiff() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try initializeRepository(at: directory)
        try "root\n".write(to: directory.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "root.txt"], cwd: directory)
        try runGit(["commit", "-m", "root commit"], cwd: directory)
        let rootSha = try gitOutput(["rev-list", "--max-parents=0", "HEAD"], cwd: directory)

        let session = PickyGitDiffReviewProvider().makeSession()
        _ = try await session.load(cwd: directory.path)
        let files = try await session.loadCommitFiles(commitSha: rootSha)
        let file = try #require(files.first { $0.displayPath == "root.txt" })
        let diff = try await session.loadCommitDiff(commitSha: rootSha, fileID: file.id)
        await session.close()

        #expect(file.status == .added)
        #expect(file.insertions == 1)
        #expect(diff.contains("diff --git a/root.txt b/root.txt"))
        #expect(diff.contains("+root"))
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
        _ = try gitOutput(arguments, cwd: cwd)
    }

    private func gitOutput(_ arguments: [String], cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = cwd
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
