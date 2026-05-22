//
//  PickyDiffReviewGitTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("Diff review git layer")
struct PickyDiffReviewGitTests {
    @Test func parseStatusPorcelainZ_handlesEmptyOutput() {
        let info = PickyDiffReviewGit.parseStatusPorcelainZ("")

        #expect(info.hasChanges == false)
        #expect(info.hasReviewableChanges == false)
        #expect(info.hasUntracked == false)
        #expect(info.hasTrackedDeletions == false)
        #expect(info.hasRenames == false)
        #expect(info.untrackedPaths.isEmpty)
    }

    @Test func parseStatusPorcelainZ_handlesModifiedRenameUntrackedAndDeleted() {
        let output = [
            " M src/existing.ts",
            "R  src/renamed.ts",
            "src/original.ts",
            "?? src/new-file.ts",
            " D src/deleted.ts",
            "?? dist/app.min.js",
        ].joined(separator: "\0") + "\0"

        let info = PickyDiffReviewGit.parseStatusPorcelainZ(output)

        #expect(info.hasChanges == true)
        #expect(info.hasReviewableChanges == true)
        #expect(info.hasUntracked == true)
        #expect(info.hasTrackedDeletions == true)
        #expect(info.hasRenames == true)
        #expect(info.untrackedPaths == ["src/new-file.ts"])
    }

    @Test func parseNameStatus_handlesBasicStatuses() {
        let output = [
            "A\tsrc/added.ts",
            "M\tsrc/modified.ts",
            "D\tsrc/deleted.ts",
            "R001\tsrc/old.ts\tsrc/new.ts",
        ].joined(separator: "\n")

        let changes = PickyDiffReviewGit.parseNameStatus(output)

        #expect(changes == [
            PickyDiffReviewChangedPath(status: .added, oldPath: nil, newPath: "src/added.ts"),
            PickyDiffReviewChangedPath(status: .modified, oldPath: "src/modified.ts", newPath: "src/modified.ts"),
            PickyDiffReviewChangedPath(status: .deleted, oldPath: "src/deleted.ts", newPath: nil),
            PickyDiffReviewChangedPath(status: .renamed, oldPath: "src/old.ts", newPath: "src/new.ts"),
        ])
    }

    @Test func shouldNormalizeBranchChanges_handlesRenameAndUntrackedDeletionCases() {
        let deletion = [PickyDiffReviewChangedPath(status: .deleted, oldPath: "src/old.ts", newPath: nil)]
        let modification = [PickyDiffReviewChangedPath(status: .modified, oldPath: "src/file.ts", newPath: "src/file.ts")]

        #expect(PickyDiffReviewGit.shouldNormalizeBranchChanges(
            trackedChanges: modification,
            workingTreeStatus: statusInfo(hasUntracked: false, hasRenames: true)
        ) == true)
        #expect(PickyDiffReviewGit.shouldNormalizeBranchChanges(
            trackedChanges: deletion,
            workingTreeStatus: statusInfo(hasUntracked: true, hasTrackedDeletions: true, untrackedPaths: ["src/new.ts"])
        ) == true)
        #expect(PickyDiffReviewGit.shouldNormalizeBranchChanges(
            trackedChanges: modification,
            workingTreeStatus: statusInfo(hasUntracked: true, untrackedPaths: ["src/new.ts"])
        ) == false)
        #expect(PickyDiffReviewGit.shouldNormalizeBranchChanges(
            trackedChanges: modification,
            workingTreeStatus: statusInfo()
        ) == false)
    }

    @Test func classifyFilePath_matchesReferenceExtensionRules() {
        #expect(PickyDiffReviewGit.classifyFilePath("asset.png").kind == .image)
        #expect(PickyDiffReviewGit.classifyFilePath("photo.JPG").kind == .image)
        #expect(PickyDiffReviewGit.classifyFilePath("bin/app.exe").kind == .binary)
        #expect(PickyDiffReviewGit.classifyFilePath("src/file.ts").kind == .text)
        #expect(PickyDiffReviewGit.classifyFilePath("dist/app.MIN.JS").kind == .text)
    }

    @Test func isIncludedReviewPath_excludesMinifiedJsAndCssOnly() {
        #expect(PickyDiffReviewGit.isIncludedReviewPath("dist/app.min.js") == false)
        #expect(PickyDiffReviewGit.isIncludedReviewPath("dist/site.MIN.CSS") == false)
        #expect(PickyDiffReviewGit.isIncludedReviewPath("src/app.js") == true)
        #expect(PickyDiffReviewGit.isIncludedReviewPath("src/style.css") == true)
        #expect(PickyDiffReviewGit.isIncludedReviewPath("README.md") == true)
    }

    @Test func isWorkingTreeCommitSha_matchesSentinelOnly() {
        #expect(PickyDiffReviewGit.isWorkingTreeCommitSha("__pi_working_tree__") == true)
        #expect(PickyDiffReviewGit.isWorkingTreeCommitSha("HEAD") == false)
        #expect(PickyDiffReviewGit.isWorkingTreeCommitSha("") == false)
    }

    @Test func diffReviewJSONEncoder_keepsNullOptionalFields() throws {
        let data = ReviewWindowData(
            repoRoot: "/tmp/repo",
            files: [],
            commits: [],
            branchBaseRef: nil,
            branchMergeBaseSha: nil,
            repositoryHasHead: false
        )

        let json = String(data: try JSONEncoder.diffReview.encode(data), encoding: .utf8) ?? ""

        #expect(json.contains("\"branchBaseRef\":null"))
        #expect(json.contains("\"branchMergeBaseSha\":null"))
    }

    @Test func reviewWindowData_emptyRepo_returnsNoFiles() async throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await shell("git init -q .", cwd: tmp)
        try await shell("git -c user.email=test@e -c user.name=t commit --allow-empty -m init -q", cwd: tmp)

        let data = try await PickyDiffReviewGit.loadReviewWindowData(cwd: tmp)

        #expect(data.repositoryHasHead == true)
        #expect(data.files.isEmpty)
    }

    @Test func reviewWindowData_addedFile_isReturned() async throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await shell("git init -q .", cwd: tmp)
        try await shell("git -c user.email=test@e -c user.name=t commit --allow-empty -m init -q", cwd: tmp)
        try "hello\n".write(to: tmp.appendingPathComponent("new-file.ts"), atomically: true, encoding: .utf8)

        let data = try await PickyDiffReviewGit.loadReviewWindowData(cwd: tmp)

        #expect(data.repositoryHasHead == true)
        #expect(data.files.map(\.path) == ["new-file.ts"])
        #expect(data.files.first?.worktreeStatus == .added)
        #expect(data.files.first?.hasWorkingTreeFile == true)
    }

    @Test func loadFileContents_workingTreeSymlinkReturnsLinkTarget() async throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await shell("git init -q .", cwd: tmp)
        try await shell("git -c user.email=test@e -c user.name=t commit --allow-empty -m init -q", cwd: tmp)
        try "target-text-payload".write(to: tmp.appendingPathComponent("target-file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: tmp.appendingPathComponent("leak.txt").path, withDestinationPath: "target-file.txt")

        let data = try await PickyDiffReviewGit.loadReviewWindowData(cwd: tmp)
        let file = try #require(data.files.first { $0.path == "leak.txt" })
        let contents = try await PickyDiffReviewGit.loadFileContents(
            repoRoot: tmp,
            file: file,
            scope: .all,
            commitSha: nil,
            branchMergeBaseSha: data.branchMergeBaseSha
        )

        #expect(contents.modifiedContent == "target-file.txt")
        #expect(contents.modifiedContent != "target-text-payload")
    }

    private func statusInfo(
        hasUntracked: Bool = false,
        hasTrackedDeletions: Bool = false,
        hasRenames: Bool = false,
        untrackedPaths: [String] = []
    ) -> PickyDiffReviewWorkingTreeStatusInfo {
        PickyDiffReviewWorkingTreeStatusInfo(
            hasChanges: hasUntracked || hasTrackedDeletions || hasRenames,
            hasReviewableChanges: hasUntracked || hasTrackedDeletions || hasRenames,
            hasUntracked: hasUntracked,
            hasTrackedDeletions: hasTrackedDeletions,
            hasRenames: hasRenames,
            untrackedPaths: untrackedPaths
        )
    }

    private func temporaryDirectory() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
    }

    private func shell(_ command: String, cwd: URL) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = cwd

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                throw ShellError(command: command, output: [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        }.value
    }

    private struct ShellError: Error, CustomStringConvertible {
        let command: String
        let output: String

        var description: String {
            "Command failed: \(command)\n\(output)"
        }
    }
}
