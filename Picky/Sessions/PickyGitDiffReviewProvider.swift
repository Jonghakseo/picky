//
//  PickyGitDiffReviewProvider.swift
//  Picky
//
//  Git diff data loader for the HUD diff viewer.
//

import Foundation

enum PickyGitDiffViewerScope: String, CaseIterable, Codable, Sendable {
    case branch
    case worktree

    var title: String {
        switch self {
        case .branch: return "Branch"
        case .worktree: return "Worktree"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .branch: return "Branch diff"
        case .worktree: return "Worktree diff"
        }
    }
}

enum PickyGitDiffChangeStatus: String, Codable, Sendable {
    case modified
    case added
    case deleted
    case renamed

    var shortLabel: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        }
    }
}

struct PickyGitDiffFile: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let path: String
    let oldPath: String?
    let newPath: String?
    let displayPath: String
    let status: PickyGitDiffChangeStatus
    let insertions: Int
    let deletions: Int
}

struct PickyGitDiffScopeData: Equatable, Codable, Sendable {
    let scope: PickyGitDiffViewerScope
    let baseLabel: String
    let targetLabel: String
    let files: [PickyGitDiffFile]
    let insertions: Int
    let deletions: Int

    var fileCount: Int { files.count }
    var hasChanges: Bool { !files.isEmpty }
}

struct PickyGitDiffViewerData: Equatable, Codable, Sendable {
    let repoRoot: String
    let repositoryName: String
    let branchName: String
    let branchBaseRef: String?
    let branchMergeBaseSha: String?
    let repositoryHasHead: Bool
    let scopes: [PickyGitDiffScopeData]

    func scopeData(_ scope: PickyGitDiffViewerScope) -> PickyGitDiffScopeData? {
        scopes.first { $0.scope == scope }
    }
}

enum PickyGitDiffReviewProviderError: LocalizedError, Equatable {
    case notGitRepository
    case missingScope(PickyGitDiffViewerScope)
    case missingFile(String)
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .notGitRepository:
            return "Not inside a git repository."
        case .missingScope(let scope):
            return "No \(scope.title.lowercased()) diff is available."
        case .missingFile(let fileID):
            return "Diff file is no longer available: \(fileID)"
        case .gitFailed(let message):
            return message
        }
    }
}

struct PickyGitDiffReviewProvider: Sendable {
    func load(cwd: String) async throws -> PickyGitDiffViewerData {
        try await Task.detached(priority: .utility) {
            try Self.loadSynchronously(cwd: cwd)
        }.value
    }

    func loadDiff(cwd: String, scope: PickyGitDiffViewerScope, fileID: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            let data = try Self.loadSynchronously(cwd: cwd)
            guard let scopeData = data.scopeData(scope) else { throw PickyGitDiffReviewProviderError.missingScope(scope) }
            guard let file = scopeData.files.first(where: { $0.id == fileID }) else { throw PickyGitDiffReviewProviderError.missingFile(fileID) }
            return try Self.diffSynchronously(cwd: cwd, data: data, scope: scope, file: file)
        }.value
    }

    static func loadSynchronously(cwd: String) throws -> PickyGitDiffViewerData {
        let repoRoot = try getRepoRoot(cwd: cwd)
        let repositoryHasHead = hasHead(repoRoot: repoRoot)
        let branchName = currentBranch(repoRoot: repoRoot)
        let repositoryName = remoteWebURLForOrigin(repoRoot: repoRoot).flatMap(PickyGitRepositoryStatus.remoteRepositoryName(from:))
            ?? URL(fileURLWithPath: repoRoot, isDirectory: true).lastPathComponent
        let reviewBase = repositoryHasHead ? findReviewBase(repoRoot: repoRoot, branch: branchName) : nil
        let branchComparisonBase = reviewBase?.mergeBase ?? (repositoryHasHead ? "HEAD" : nil)
        let worktreeComparisonBase = repositoryHasHead ? "HEAD" : nil

        let branchScope = try makeScopeData(
            repoRoot: repoRoot,
            scope: .branch,
            baseRevision: branchComparisonBase,
            baseLabel: reviewBase?.baseRef ?? (repositoryHasHead ? "HEAD" : "Empty tree"),
            targetLabel: "Working tree"
        )
        let worktreeScope = try makeScopeData(
            repoRoot: repoRoot,
            scope: .worktree,
            baseRevision: worktreeComparisonBase,
            baseLabel: repositoryHasHead ? "HEAD" : "Empty tree",
            targetLabel: "Working tree"
        )

        return PickyGitDiffViewerData(
            repoRoot: repoRoot,
            repositoryName: repositoryName,
            branchName: branchName,
            branchBaseRef: reviewBase?.baseRef,
            branchMergeBaseSha: branchComparisonBase,
            repositoryHasHead: repositoryHasHead,
            scopes: [branchScope, worktreeScope]
        )
    }

    static func diffSynchronously(
        cwd: String,
        data: PickyGitDiffViewerData,
        scope: PickyGitDiffViewerScope,
        file: PickyGitDiffFile
    ) throws -> String {
        let baseRevision: String?
        switch scope {
        case .branch:
            baseRevision = data.branchMergeBaseSha ?? (data.repositoryHasHead ? "HEAD" : nil)
        case .worktree:
            baseRevision = data.repositoryHasHead ? "HEAD" : nil
        }
        let path = file.newPath ?? file.oldPath ?? file.path
        return try runSnapshotDiff(repoRoot: data.repoRoot, baseRevision: baseRevision, mode: .unifiedDiff(path: path))
    }

    private struct ReviewBaseInfo: Equatable {
        let mergeBase: String
        let baseRef: String
    }

    private enum SnapshotDiffMode {
        case nameStatus
        case numstat
        case unifiedDiff(path: String)
    }

    private struct ChangedPath: Equatable {
        let status: PickyGitDiffChangeStatus
        let oldPath: String?
        let newPath: String?

        var displayPath: String {
            if status == .renamed {
                return "\(oldPath ?? "") → \(newPath ?? "")"
            }
            return newPath ?? oldPath ?? "(unknown)"
        }

        var primaryPath: String {
            newPath ?? oldPath ?? displayPath
        }
    }

    private struct Numstat: Equatable {
        let insertions: Int
        let deletions: Int
    }

    private static func makeScopeData(
        repoRoot: String,
        scope: PickyGitDiffViewerScope,
        baseRevision: String?,
        baseLabel: String,
        targetLabel: String
    ) throws -> PickyGitDiffScopeData {
        let changedPaths = parseNameStatus(try runSnapshotDiff(repoRoot: repoRoot, baseRevision: baseRevision, mode: .nameStatus))
        let statsByPath = parseNumstatByPath(try runSnapshotDiff(repoRoot: repoRoot, baseRevision: baseRevision, mode: .numstat))
        let files: [PickyGitDiffFile] = changedPaths
            .filter { isIncludedReviewPath($0.primaryPath) }
            .map { change in
                let stats = statsByPath[change.primaryPath] ?? statsByPath[change.displayPath] ?? Numstat(insertions: 0, deletions: 0)
                return PickyGitDiffFile(
                    id: "\(scope.rawValue)::\(change.status.rawValue)::\(change.displayPath)",
                    path: change.primaryPath,
                    oldPath: change.oldPath,
                    newPath: change.newPath,
                    displayPath: change.displayPath,
                    status: change.status,
                    insertions: stats.insertions,
                    deletions: stats.deletions
                )
            }
            .sorted { (lhs: PickyGitDiffFile, rhs: PickyGitDiffFile) in lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending }
        let totals = files.reduce(into: Numstat(insertions: 0, deletions: 0)) { result, file in
            result = Numstat(insertions: result.insertions + file.insertions, deletions: result.deletions + file.deletions)
        }
        return PickyGitDiffScopeData(
            scope: scope,
            baseLabel: baseLabel,
            targetLabel: targetLabel,
            files: files,
            insertions: totals.insertions,
            deletions: totals.deletions
        )
    }

    private static func getRepoRoot(cwd: String) throws -> String {
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else { throw PickyGitDiffReviewProviderError.notGitRepository }
        let result = runGit(["rev-parse", "--show-toplevel"], cwd: trimmedCwd)
        guard result.exitCode == 0 else { throw PickyGitDiffReviewProviderError.notGitRepository }
        let repoRoot = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoRoot.isEmpty else { throw PickyGitDiffReviewProviderError.notGitRepository }
        return repoRoot
    }

    private static func hasHead(repoRoot: String) -> Bool {
        runGit(["rev-parse", "--verify", "HEAD"], cwd: repoRoot).exitCode == 0
    }

    private static func currentBranch(repoRoot: String) -> String {
        let branch = runGit(["branch", "--show-current"], cwd: repoRoot).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { return branch }
        let shortHash = runGit(["rev-parse", "--short", "HEAD"], cwd: repoRoot).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return shortHash.isEmpty ? "HEAD" : shortHash
    }

    private static func getUpstreamRef(repoRoot: String) -> String? {
        nonEmptyGitOutput(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: repoRoot)
    }

    private static func getOriginHeadRef(repoRoot: String) -> String? {
        nonEmptyGitOutput(["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], cwd: repoRoot)
    }

    private static func nonEmptyGitOutput(_ arguments: [String], cwd: String) -> String? {
        let result = runGit(arguments, cwd: cwd)
        guard result.exitCode == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func findReviewBase(repoRoot: String, branch: String) -> ReviewBaseInfo? {
        var candidates: [String] = []
        if let upstreamRef = getUpstreamRef(repoRoot: repoRoot), !isSameBranchRef(upstreamRef, branch: branch) {
            candidates.append(upstreamRef)
        }
        if let originHeadRef = getOriginHeadRef(repoRoot: repoRoot) {
            candidates.append(originHeadRef)
        }
        candidates.append(contentsOf: ["origin/main", "origin/master", "origin/develop", "main", "master", "develop"])

        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty && !seen.contains(candidate) {
            seen.insert(candidate)
            let result = runGit(["merge-base", "HEAD", candidate], cwd: repoRoot)
            guard result.exitCode == 0 else { continue }
            let mergeBase = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mergeBase.isEmpty { return ReviewBaseInfo(mergeBase: mergeBase, baseRef: candidate) }
        }
        return nil
    }

    private static func isSameBranchRef(_ ref: String, branch: String) -> Bool {
        guard !branch.isEmpty, branch != "HEAD" else { return false }
        return ref == branch || ref.hasSuffix("/\(branch)")
    }

    private static func remoteWebURLForOrigin(repoRoot: String) -> URL? {
        let result = runGit(["remote", "get-url", "origin"], cwd: repoRoot)
        guard result.exitCode == 0 else { return nil }
        return PickyGitRepositoryStatus.convertRemoteURLToWeb(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runSnapshotDiff(repoRoot: String, baseRevision: String?, mode: SnapshotDiffMode) throws -> String {
        let tmpName = "/tmp/picky-diff-viewer-index.XXXXXX"
        var lines = [
            "set -euo pipefail",
            "tmp_index=$(mktemp \(shellQuote(tmpName)))",
            "trap 'rm -f \"$tmp_index\"' EXIT",
            "export GIT_INDEX_FILE=\"$tmp_index\""
        ]
        if let baseRevision {
            lines.append("git read-tree \(shellQuote(baseRevision))")
        } else {
            lines.append("rm -f \"$tmp_index\"")
        }
        lines.append("git add -A -- .")
        let baseArgument = baseRevision.map(shellQuote)
        switch mode {
        case .nameStatus:
            if let baseArgument {
                lines.append("git diff --cached --find-renames -M --name-status \(baseArgument) --")
            } else {
                lines.append("git diff --cached --find-renames -M --name-status --root --")
            }
        case .numstat:
            if let baseArgument {
                lines.append("git diff --cached --numstat \(baseArgument) --")
            } else {
                lines.append("git diff --cached --numstat --root --")
            }
        case .unifiedDiff(let path):
            let pathArgument = shellQuote(path)
            if let baseArgument {
                lines.append("git diff --cached --find-renames -M --no-color --unified=80 \(baseArgument) -- \(pathArgument)")
            } else {
                lines.append("git diff --cached --find-renames -M --no-color --unified=80 --root -- \(pathArgument)")
            }
        }
        let result = runBash(lines.joined(separator: "\n"), cwd: repoRoot)
        guard result.exitCode == 0 else {
            let message = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw PickyGitDiffReviewProviderError.gitFailed(message.isEmpty ? "git diff failed" : message)
        }
        return result.stdout
    }

    private static func parseNameStatus(_ output: String) -> [ChangedPath] {
        output.split(whereSeparator: { $0.isNewline }).compactMap { rawLine in
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let code = fields.first?.first else { return nil }
            switch code {
            case "M":
                guard fields.count >= 2 else { return nil }
                return ChangedPath(status: .modified, oldPath: fields[1], newPath: fields[1])
            case "A":
                guard fields.count >= 2 else { return nil }
                return ChangedPath(status: .added, oldPath: nil, newPath: fields[1])
            case "D":
                guard fields.count >= 2 else { return nil }
                return ChangedPath(status: .deleted, oldPath: fields[1], newPath: nil)
            case "R":
                guard fields.count >= 3 else { return nil }
                return ChangedPath(status: .renamed, oldPath: fields[1], newPath: fields[2])
            default:
                return nil
            }
        }
    }

    private static func parseNumstatByPath(_ output: String) -> [String: Numstat] {
        output.split(whereSeparator: { $0.isNewline }).reduce(into: [String: Numstat]()) { result, rawLine in
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3,
                  let insertions = Int(fields[0]),
                  let deletions = Int(fields[1]) else { return }
            let rawPath = fields.dropFirst(2).joined(separator: "\t")
            for path in numstatPathAliases(rawPath) {
                result[path] = Numstat(insertions: insertions, deletions: deletions)
            }
        }
    }

    private static func numstatPathAliases(_ rawPath: String) -> [String] {
        var aliases = [rawPath]
        guard rawPath.contains(" => ") else { return aliases }

        if let openBrace = rawPath.firstIndex(of: "{"), let closeBrace = rawPath[openBrace...].firstIndex(of: "}") {
            let prefix = String(rawPath[..<openBrace])
            let suffixStart = rawPath.index(after: closeBrace)
            let suffix = String(rawPath[suffixStart...])
            let renameBodyStart = rawPath.index(after: openBrace)
            let renameBody = String(rawPath[renameBodyStart..<closeBrace])
            let parts = renameBody.components(separatedBy: " => ")
            if parts.count == 2 {
                aliases.append(prefix + parts[0] + suffix)
                aliases.append(prefix + parts[1] + suffix)
                aliases.append("\(prefix)\(parts[0])\(suffix) → \(prefix)\(parts[1])\(suffix)")
            }
        } else {
            let parts = rawPath.components(separatedBy: " => ")
            if parts.count == 2 {
                aliases.append(parts[0])
                aliases.append(parts[1])
                aliases.append("\(parts[0]) → \(parts[1])")
            }
        }
        return Array(Set(aliases))
    }

    private static func isIncludedReviewPath(_ path: String) -> Bool {
        let lowerPath = path.lowercased()
        let fileName = lowerPath.split(separator: "/").last.map(String.init) ?? lowerPath
        guard !fileName.isEmpty else { return false }
        if fileName.hasSuffix(".min.js") || fileName.hasSuffix(".min.css") { return false }
        return true
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func runGit(_ arguments: [String], cwd: String) -> ProcessResult {
        runProcess(executable: "/usr/bin/env", arguments: ["git", "-C", cwd] + arguments, cwd: nil)
    }

    private static func runBash(_ script: String, cwd: String) -> ProcessResult {
        runProcess(executable: "/bin/bash", arguments: ["-lc", script], cwd: cwd)
    }

    private final class PipeDataCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func stringValue() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(data: snapshot, encoding: .utf8) ?? ""
        }
    }

    private static func runProcess(executable: String, arguments: [String], cwd: String?) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let stdoutCollector = PipeDataCollector()
        let stderrCollector = PipeDataCollector()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutCollector.stringValue(),
            stderr: stderrCollector.stringValue()
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
