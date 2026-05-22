//
//  PickyDiffReviewGit.swift
//  Picky
//
//  Native git layer for the diff review HUD.
//

import Foundation

enum PickyDiffReviewGitError: LocalizedError, Equatable {
    case notAGitRepository(String)
    case gitFailure(message: String)

    var errorDescription: String? {
        switch self {
        case .notAGitRepository(let message): message
        case .gitFailure(let message): message
        }
    }
}

struct PickyDiffReviewChangedPath: Equatable {
    let status: ChangeStatus
    let oldPath: String?
    let newPath: String?
}

struct PickyDiffReviewWorkingTreeStatusInfo: Equatable {
    var hasChanges: Bool
    var hasReviewableChanges: Bool
    var hasUntracked: Bool
    var hasTrackedDeletions: Bool
    var hasRenames: Bool
    var untrackedPaths: [String]

    static var empty: PickyDiffReviewWorkingTreeStatusInfo {
        PickyDiffReviewWorkingTreeStatusInfo(
            hasChanges: false,
            hasReviewableChanges: false,
            hasUntracked: false,
            hasTrackedDeletions: false,
            hasRenames: false,
            untrackedPaths: []
        )
    }
}

enum PickyDiffReviewGit {
    static let workingTreeCommitSha = "__pi_working_tree__"

    private static let workingTreeCommitShortSha = "WT"
    private static let workingTreeCommitSubject = "Uncommitted changes"

    static func isWorkingTreeCommitSha(_ sha: String) -> Bool {
        sha == workingTreeCommitSha
    }

    static func resolveRepoRoot(cwd: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let path = try getRepoRoot(cwd: cwd)
            return URL(fileURLWithPath: path).standardizedFileURL
        }.value
    }

    static func loadReviewWindowData(cwd: URL) async throws -> ReviewWindowData {
        try await Task.detached(priority: .utility) {
            try getReviewWindowData(cwd: cwd)
        }.value
    }

    static func loadCommitFiles(repoRoot: URL, sha: String) async throws -> [ReviewFile] {
        try await Task.detached(priority: .utility) {
            try getCommitFiles(repoRoot: repoRoot.standardizedFileURL.path, sha: sha)
        }.value
    }

    static func loadFileContents(
        repoRoot: URL,
        file: ReviewFile,
        scope: ReviewScope,
        commitSha: String?,
        branchMergeBaseSha: String?
    ) async throws -> ReviewFileContents {
        try await Task.detached(priority: .utility) {
            try loadReviewFileContents(
                repoRoot: repoRoot.standardizedFileURL.path,
                file: file,
                scope: scope,
                commitSha: commitSha,
                branchMergeBaseSha: branchMergeBaseSha
            )
        }.value
    }

    static func parseNameStatusLine(_ parts: [String]) -> PickyDiffReviewChangedPath? {
        guard let statusField = parts.first, let code = statusField.first else { return nil }
        if code == "R" {
            guard parts.count >= 3 else { return nil }
            return PickyDiffReviewChangedPath(status: .renamed, oldPath: parts[1], newPath: parts[2])
        }
        guard parts.count >= 2 else { return nil }
        let path = parts[1]
        if code == "M" { return PickyDiffReviewChangedPath(status: .modified, oldPath: path, newPath: path) }
        if code == "A" { return PickyDiffReviewChangedPath(status: .added, oldPath: nil, newPath: path) }
        if code == "D" { return PickyDiffReviewChangedPath(status: .deleted, oldPath: path, newPath: nil) }
        return nil
    }

    static func parseNameStatus(_ output: String) -> [PickyDiffReviewChangedPath] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { parseNameStatusLine($0.components(separatedBy: "\t")) }
    }

    static func parseStatusPorcelainZ(_ output: String) -> PickyDiffReviewWorkingTreeStatusInfo {
        var info = PickyDiffReviewWorkingTreeStatusInfo.empty
        let tokens = output.components(separatedBy: "\0")
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.isEmpty {
                index += 1
                continue
            }

            let code = String(token.prefix(2))
            let path = token.count > 3 ? String(token.dropFirst(3)) : ""
            let isRenameOrCopy = code.contains("R") || code.contains("C")
            let isReviewablePath = code != "!!" && !path.isEmpty && isIncludedReviewPath(path)
            if code != "!!" {
                info.hasChanges = true
            }
            if isReviewablePath {
                info.hasReviewableChanges = true
            }
            if code == "??" {
                if isReviewablePath {
                    info.hasUntracked = true
                    info.untrackedPaths.append(path)
                }
            } else if isReviewablePath {
                if code.contains("D") { info.hasTrackedDeletions = true }
                if isRenameOrCopy { info.hasRenames = true }
            }
            index += isRenameOrCopy ? 2 : 1
        }
        return info
    }

    static func shouldNormalizeBranchChanges(
        trackedChanges: [PickyDiffReviewChangedPath],
        workingTreeStatus: PickyDiffReviewWorkingTreeStatusInfo
    ) -> Bool {
        if workingTreeStatus.hasRenames { return true }
        if !workingTreeStatus.hasUntracked { return false }
        return trackedChanges.contains { $0.status == .deleted }
    }

    static func classifyFilePath(_ path: String) -> (kind: ReviewFileKind, mimeType: String?) {
        let ext = fileExtension(path)
        if let mimeType = imageMimeTypes[ext] {
            return (.image, mimeType)
        }
        if binaryExtensions.contains(ext) {
            return (.binary, nil)
        }
        return (.text, nil)
    }

    static func isIncludedReviewPath(_ path: String) -> Bool {
        let lowerPath = path.lowercased()
        let fileName = lowerPath.split(separator: "/").last.map(String.init) ?? lowerPath
        if fileName.isEmpty { return false }
        if fileName.hasSuffix(".min.js") || fileName.hasSuffix(".min.css") { return false }
        return true
    }

    private struct ReviewBaseInfo {
        let mergeBase: String
        let baseRef: String
    }

    private struct GitProcessDataResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data

        var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    private enum GitProcessResult {
        case success(exitCode: Int32, stdout: String, stderr: String)
        case failure(message: String)
    }

    private static func getReviewWindowData(cwd: URL) throws -> ReviewWindowData {
        let repoRoot = try getRepoRoot(cwd: cwd)
        let repositoryHasHead = hasHead(repoRoot: repoRoot)
        let reviewBase = repositoryHasHead ? findReviewBase(repoRoot: repoRoot) : nil
        let branchComparisonBase = reviewBase?.mergeBase ?? (repositoryHasHead ? "HEAD" : nil)
        let workingTreeStatus = getWorkingTreeStatusInfo(repoRoot: repoRoot)
        let branchChanges = repositoryHasHead
            ? getBranchReviewChanges(repoRoot: repoRoot, branchComparisonBase: branchComparisonBase, workingTreeStatus: workingTreeStatus)
            : getWorkingTreeReviewChanges(repoRoot: repoRoot, repositoryHasHead: false)
        let files = branchChanges
            .filter { isIncludedReviewPath($0.newPath ?? $0.oldPath ?? "") }
            .map(toBranchReviewFile)
            .sorted(by: compareReviewFiles)
        let commits = reviewBase.map { listRangeCommits(repoRoot: repoRoot, range: "\($0.mergeBase)..HEAD", limit: 100) } ?? []
        let workingTreeCommit = workingTreeStatus.hasReviewableChanges ? [createWorkingTreeCommitInfo()] : []
        let fallbackCommits = repositoryHasHead && files.isEmpty && commits.isEmpty && !workingTreeStatus.hasReviewableChanges
            ? listRangeCommits(repoRoot: repoRoot, range: "HEAD", limit: 20)
            : commits

        return ReviewWindowData(
            repoRoot: repoRoot,
            files: files,
            commits: workingTreeCommit + fallbackCommits,
            branchBaseRef: reviewBase?.baseRef,
            branchMergeBaseSha: branchComparisonBase,
            repositoryHasHead: repositoryHasHead
        )
    }

    private static func getRepoRoot(cwd: URL) throws -> String {
        let result = runGitProcess(["rev-parse", "--show-toplevel"], cwd: cwd.standardizedFileURL.path)
        switch result {
        case .failure(let message):
            throw PickyDiffReviewGitError.gitFailure(message: message)
        case .success(let exitCode, let stdout, let stderr):
            guard exitCode == 0 else {
                throw PickyDiffReviewGitError.notAGitRepository(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not inside a git repository." : stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func hasHead(repoRoot: String) -> Bool {
        git(["rev-parse", "--verify", "HEAD"], repoRoot: repoRoot) != nil
    }

    private static func currentBranch(repoRoot: String) -> String {
        let output = git(["branch", "--show-current"], repoRoot: repoRoot) ?? ""
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? "HEAD" : branch
    }

    private static func getUpstreamRef(repoRoot: String) -> String? {
        let value = runGitAllowFailure(repoRoot: repoRoot, args: [
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func getOriginHeadRef(repoRoot: String) -> String? {
        let value = runGitAllowFailure(repoRoot: repoRoot, args: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isSameBranchRef(_ ref: String, branch: String) -> Bool {
        if branch.isEmpty || branch == "HEAD" { return false }
        return ref == branch || ref.hasSuffix("/\(branch)")
    }

    private static func findReviewBase(repoRoot: String) -> ReviewBaseInfo? {
        let branch = currentBranch(repoRoot: repoRoot)
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
            let mergeBase = runGitAllowFailure(repoRoot: repoRoot, args: ["merge-base", "HEAD", candidate])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !mergeBase.isEmpty {
                return ReviewBaseInfo(mergeBase: mergeBase, baseRef: candidate)
            }
        }
        return nil
    }

    private static func getWorkingTreeStatusInfo(repoRoot: String) -> PickyDiffReviewWorkingTreeStatusInfo {
        parseStatusPorcelainZ(runGitAllowFailure(repoRoot: repoRoot, args: ["status", "--porcelain=1", "--untracked-files=all", "-z"]))
    }

    private static func toDisplayPath(_ change: PickyDiffReviewChangedPath) -> String {
        if change.status == .renamed {
            return "\(change.oldPath ?? "") -> \(change.newPath ?? "")"
        }
        return change.newPath ?? change.oldPath ?? "(unknown)"
    }

    private static func toComparison(_ change: PickyDiffReviewChangedPath) -> ReviewFileComparison {
        ReviewFileComparison(
            status: change.status,
            oldPath: change.oldPath,
            newPath: change.newPath,
            displayPath: toDisplayPath(change),
            hasOriginal: change.oldPath != nil,
            hasModified: change.newPath != nil
        )
    }

    private static func buildBranchFileId(path: String, hasWorkingTreeFile: Bool, gitDiff: ReviewFileComparison) -> String {
        ["branch", path, hasWorkingTreeFile ? "working" : "gone", gitDiff.displayPath].joined(separator: "::")
    }

    private static func buildCommitFileId(sha: String, comparison: ReviewFileComparison) -> String {
        ["commit", sha, comparison.displayPath].joined(separator: "::")
    }

    private static func getRevisionContent(repoRoot: String, revision: String, path: String) -> String {
        let result = runGitProcessData(["show", "\(revision):\(path)"], cwd: repoRoot)
        guard result.exitCode == 0 else { return "" }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }

    private static func getWorkingTreeContent(repoRoot: String, path: String) -> String {
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(path)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func getWorkingTreeBytes(repoRoot: String, path: String) -> Data? {
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(path)
        return try? Data(contentsOf: url)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func getRevisionBytes(repoRoot: String, revision: String, path: String) -> Data? {
        let result = runGitProcessData(["show", "\(revision):\(path)"], cwd: repoRoot)
        guard result.exitCode == 0 else { return nil }
        return result.stdout
    }

    private static let imageMimeTypes: [String: String] = [
        ".avif": "image/avif",
        ".bmp": "image/bmp",
        ".gif": "image/gif",
        ".ico": "image/x-icon",
        ".jpeg": "image/jpeg",
        ".jpg": "image/jpeg",
        ".png": "image/png",
        ".webp": "image/webp",
    ]

    private static let binaryExtensions: Set<String> = [
        ".7z",
        ".a",
        ".avi",
        ".avif",
        ".bin",
        ".bmp",
        ".class",
        ".dll",
        ".dylib",
        ".eot",
        ".exe",
        ".gif",
        ".gz",
        ".ico",
        ".jar",
        ".jpeg",
        ".jpg",
        ".lockb",
        ".map",
        ".mov",
        ".mp3",
        ".mp4",
        ".o",
        ".otf",
        ".pdf",
        ".png",
        ".pyc",
        ".so",
        ".svgz",
        ".tar",
        ".ttf",
        ".wasm",
        ".webm",
        ".webp",
        ".woff",
        ".woff2",
        ".zip",
    ]

    private static func fileExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "" : ".\(ext)"
    }

    private static func bufferToDataUrl(_ buffer: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(buffer.base64EncodedString())"
    }

    private static func toReviewFile(
        change: PickyDiffReviewChangedPath,
        id: String,
        worktreeStatus: ChangeStatus?,
        hasWorkingTreeFile: Bool
    ) -> ReviewFile {
        let comparison = toComparison(change)
        let path = change.newPath ?? change.oldPath ?? comparison.displayPath
        let meta = classifyFilePath(path)
        return ReviewFile(
            id: id,
            path: path,
            worktreeStatus: worktreeStatus,
            hasWorkingTreeFile: hasWorkingTreeFile,
            inGitDiff: true,
            gitDiff: comparison,
            kind: meta.kind,
            mimeType: meta.mimeType
        )
    }

    private static func loadBinarySideFromWorkingTree(repoRoot: String, path: String?, mimeType: String?) -> (exists: Bool, previewUrl: String?) {
        guard let path, let bytes = getWorkingTreeBytes(repoRoot: repoRoot, path: path) else {
            return (false, nil)
        }
        return (true, mimeType.map { bufferToDataUrl(bytes, mimeType: $0) })
    }

    private static func loadBinarySideFromRevision(repoRoot: String, revision: String, path: String?, mimeType: String?) -> (exists: Bool, previewUrl: String?) {
        guard let path, let bytes = getRevisionBytes(repoRoot: repoRoot, revision: revision, path: path) else {
            return (false, nil)
        }
        return (true, mimeType.map { bufferToDataUrl(bytes, mimeType: $0) })
    }

    private static func mergeChangedPaths(_ groups: [PickyDiffReviewChangedPath]...) -> [PickyDiffReviewChangedPath] {
        var order: [String] = []
        var merged: [String: PickyDiffReviewChangedPath] = [:]
        for group in groups {
            for change in group {
                let key = change.newPath ?? change.oldPath ?? ""
                if key.isEmpty { continue }
                if merged[key] == nil { order.append(key) }
                merged[key] = change
            }
        }
        return order.compactMap { merged[$0] }
    }

    private static func toUntrackedChangedPaths(_ paths: [String]) -> [PickyDiffReviewChangedPath] {
        paths.map { PickyDiffReviewChangedPath(status: .added, oldPath: nil, newPath: $0) }
    }

    private static func getTrackedBranchReviewChanges(repoRoot: String, branchComparisonBase: String) -> [PickyDiffReviewChangedPath] {
        parseNameStatus(runGitAllowFailure(repoRoot: repoRoot, args: [
            "diff",
            "--find-renames",
            "-M",
            "--name-status",
            branchComparisonBase,
            "--",
        ]))
    }

    private static func getWorkingTreeSnapshotChanges(repoRoot: String, baseRevision: String?) -> [PickyDiffReviewChangedPath] {
        var scriptLines = [
            "set -euo pipefail",
            "tmp_index=$(mktemp \"/tmp/pi-diff-review-index.XXXXXX\")",
            "trap 'rm -f \"$tmp_index\"' EXIT",
            "export GIT_INDEX_FILE=\"$tmp_index\"",
        ]
        if let baseRevision {
            scriptLines.append("git read-tree \(shellQuote(baseRevision))")
        } else {
            scriptLines.append("rm -f \"$tmp_index\"")
        }
        scriptLines.append("git add -A -- .")
        scriptLines.append(baseRevision.map { "git diff --cached --find-renames -M --name-status \(shellQuote($0)) --" } ?? "git diff --cached --find-renames -M --name-status --root --")
        return parseNameStatus(runBashAllowFailure(repoRoot: repoRoot, script: scriptLines.joined(separator: "\n")))
    }

    private static func getBranchReviewChanges(
        repoRoot: String,
        branchComparisonBase: String?,
        workingTreeStatus: PickyDiffReviewWorkingTreeStatusInfo
    ) -> [PickyDiffReviewChangedPath] {
        guard let branchComparisonBase else { return [] }
        let trackedChanges = getTrackedBranchReviewChanges(repoRoot: repoRoot, branchComparisonBase: branchComparisonBase)
        if shouldNormalizeBranchChanges(trackedChanges: trackedChanges, workingTreeStatus: workingTreeStatus) {
            return getWorkingTreeSnapshotChanges(repoRoot: repoRoot, baseRevision: branchComparisonBase)
        }
        return mergeChangedPaths(trackedChanges, toUntrackedChangedPaths(workingTreeStatus.untrackedPaths))
    }

    private static func getWorkingTreeReviewChanges(repoRoot: String, repositoryHasHead: Bool) -> [PickyDiffReviewChangedPath] {
        getWorkingTreeSnapshotChanges(repoRoot: repoRoot, baseRevision: repositoryHasHead ? "HEAD" : nil)
    }

    private static func compareReviewFiles(_ lhs: ReviewFile, _ rhs: ReviewFile) -> Bool {
        lhs.path.localizedCompare(rhs.path) == .orderedAscending
    }

    private static func toBranchReviewFile(_ change: PickyDiffReviewChangedPath) -> ReviewFile {
        let comparison = toComparison(change)
        let path = change.newPath ?? change.oldPath ?? comparison.displayPath
        return toReviewFile(
            change: change,
            id: buildBranchFileId(path: path, hasWorkingTreeFile: change.newPath != nil, gitDiff: comparison),
            worktreeStatus: change.status,
            hasWorkingTreeFile: change.newPath != nil
        )
    }

    private static func listRangeCommits(repoRoot: String, range: String, limit: Int) -> [ReviewCommitInfo] {
        let separator = "\u{1f}"
        let format = ["%H", "%h", "%s", "%an", "%aI"].joined(separator: separator)
        let output = runGitAllowFailure(repoRoot: repoRoot, args: ["log", "-\(limit)", "--format=\(format)", range])
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.components(separatedBy: separator)
                let sha = parts[safe: 0] ?? ""
                guard !sha.isEmpty else { return nil }
                return ReviewCommitInfo(
                    sha: sha,
                    shortSha: parts[safe: 1] ?? String(sha.prefix(7)),
                    subject: parts[safe: 2] ?? "",
                    authorName: parts[safe: 3] ?? "",
                    authorDate: parts[safe: 4] ?? "",
                    kind: .commit
                )
            }
    }

    private static func createWorkingTreeCommitInfo() -> ReviewCommitInfo {
        ReviewCommitInfo(
            sha: workingTreeCommitSha,
            shortSha: workingTreeCommitShortSha,
            subject: workingTreeCommitSubject,
            authorName: "",
            authorDate: "",
            kind: .workingTree
        )
    }

    private static func getCommitFiles(repoRoot: String, sha: String) throws -> [ReviewFile] {
        if isWorkingTreeCommitSha(sha) {
            let repositoryHasHead = hasHead(repoRoot: repoRoot)
            return getWorkingTreeReviewChanges(repoRoot: repoRoot, repositoryHasHead: repositoryHasHead)
                .filter { isIncludedReviewPath($0.newPath ?? $0.oldPath ?? "") }
                .map { change in
                    let comparison = toComparison(change)
                    return toReviewFile(
                        change: change,
                        id: buildCommitFileId(sha: sha, comparison: comparison),
                        worktreeStatus: change.status,
                        hasWorkingTreeFile: change.newPath != nil
                    )
                }
                .sorted(by: compareReviewFiles)
        }

        let output = runGitAllowFailure(repoRoot: repoRoot, args: [
            "diff-tree",
            "--root",
            "--find-renames",
            "-M",
            "--name-status",
            "--no-commit-id",
            "-r",
            sha,
        ])
        return parseNameStatus(output)
            .filter { isIncludedReviewPath($0.newPath ?? $0.oldPath ?? "") }
            .map { change in
                let comparison = toComparison(change)
                return toReviewFile(
                    change: change,
                    id: buildCommitFileId(sha: sha, comparison: comparison),
                    worktreeStatus: nil,
                    hasWorkingTreeFile: false
                )
            }
            .sorted(by: compareReviewFiles)
    }

    private static func emptyFileContents(file: ReviewFile) -> ReviewFileContents {
        ReviewFileContents(
            originalContent: "",
            modifiedContent: "",
            kind: file.kind,
            mimeType: file.mimeType,
            originalExists: false,
            modifiedExists: false,
            originalPreviewUrl: nil,
            modifiedPreviewUrl: nil
        )
    }

    private static func loadReviewFileContents(
        repoRoot: String,
        file: ReviewFile,
        scope: ReviewScope,
        commitSha: String? = nil,
        branchMergeBaseSha: String? = nil
    ) throws -> ReviewFileContents {
        let emptyBinaryContents = emptyFileContents(file: file)

        if file.kind != .text {
            if scope == .all {
                let path = file.gitDiff?.newPath ?? (file.hasWorkingTreeFile ? file.path : nil)
                let modifiedSide = file.hasWorkingTreeFile
                    ? loadBinarySideFromWorkingTree(repoRoot: repoRoot, path: path, mimeType: file.mimeType)
                    : loadBinarySideFromRevision(repoRoot: repoRoot, revision: "HEAD", path: path, mimeType: file.mimeType)
                return ReviewFileContents(
                    originalContent: emptyBinaryContents.originalContent,
                    modifiedContent: emptyBinaryContents.modifiedContent,
                    kind: emptyBinaryContents.kind,
                    mimeType: emptyBinaryContents.mimeType,
                    originalExists: emptyBinaryContents.originalExists,
                    modifiedExists: modifiedSide.exists,
                    originalPreviewUrl: emptyBinaryContents.originalPreviewUrl,
                    modifiedPreviewUrl: modifiedSide.previewUrl
                )
            }

            guard let comparison = file.gitDiff else { return emptyBinaryContents }
            if scope == .commits {
                guard let commitSha else { return emptyBinaryContents }
                if isWorkingTreeCommitSha(commitSha) {
                    let repositoryHasHead = hasHead(repoRoot: repoRoot)
                    let originalSide = repositoryHasHead
                        ? loadBinarySideFromRevision(repoRoot: repoRoot, revision: "HEAD", path: comparison.oldPath, mimeType: file.mimeType)
                        : (exists: false, previewUrl: nil)
                    let modifiedSide = file.hasWorkingTreeFile
                        ? loadBinarySideFromWorkingTree(repoRoot: repoRoot, path: comparison.newPath, mimeType: file.mimeType)
                        : (exists: false, previewUrl: nil)
                    return ReviewFileContents(
                        originalContent: "",
                        modifiedContent: "",
                        kind: file.kind,
                        mimeType: file.mimeType,
                        originalExists: originalSide.exists,
                        modifiedExists: modifiedSide.exists,
                        originalPreviewUrl: originalSide.previewUrl,
                        modifiedPreviewUrl: modifiedSide.previewUrl
                    )
                }
                let originalSide = loadBinarySideFromRevision(repoRoot: repoRoot, revision: "\(commitSha)^", path: comparison.oldPath, mimeType: file.mimeType)
                let modifiedSide = loadBinarySideFromRevision(repoRoot: repoRoot, revision: commitSha, path: comparison.newPath, mimeType: file.mimeType)
                return ReviewFileContents(originalContent: "", modifiedContent: "", kind: file.kind, mimeType: file.mimeType, originalExists: originalSide.exists, modifiedExists: modifiedSide.exists, originalPreviewUrl: originalSide.previewUrl, modifiedPreviewUrl: modifiedSide.previewUrl)
            }

            guard let branchMergeBaseSha else { return emptyBinaryContents }
            let originalSide = loadBinarySideFromRevision(repoRoot: repoRoot, revision: branchMergeBaseSha, path: comparison.oldPath, mimeType: file.mimeType)
            let modifiedSide = file.hasWorkingTreeFile
                ? loadBinarySideFromWorkingTree(repoRoot: repoRoot, path: comparison.newPath, mimeType: file.mimeType)
                : loadBinarySideFromRevision(repoRoot: repoRoot, revision: "HEAD", path: comparison.newPath, mimeType: file.mimeType)
            return ReviewFileContents(originalContent: "", modifiedContent: "", kind: file.kind, mimeType: file.mimeType, originalExists: originalSide.exists, modifiedExists: modifiedSide.exists, originalPreviewUrl: originalSide.previewUrl, modifiedPreviewUrl: modifiedSide.previewUrl)
        }

        if scope == .all {
            let path = file.gitDiff?.newPath ?? (file.hasWorkingTreeFile ? file.path : nil)
            let content = path.map { file.hasWorkingTreeFile ? getWorkingTreeContent(repoRoot: repoRoot, path: $0) : getRevisionContent(repoRoot: repoRoot, revision: "HEAD", path: $0) } ?? ""
            return ReviewFileContents(originalContent: content, modifiedContent: content, kind: file.kind, mimeType: file.mimeType, originalExists: path != nil, modifiedExists: path != nil, originalPreviewUrl: nil, modifiedPreviewUrl: nil)
        }

        guard let comparison = file.gitDiff else { return emptyFileContents(file: file) }
        if scope == .commits {
            guard let commitSha else { return emptyFileContents(file: file) }
            if isWorkingTreeCommitSha(commitSha) {
                let repositoryHasHead = hasHead(repoRoot: repoRoot)
                let originalContent = repositoryHasHead && comparison.oldPath != nil ? getRevisionContent(repoRoot: repoRoot, revision: "HEAD", path: comparison.oldPath!) : ""
                let modifiedContent = comparison.newPath.map { file.hasWorkingTreeFile ? getWorkingTreeContent(repoRoot: repoRoot, path: $0) : "" } ?? ""
                return ReviewFileContents(originalContent: originalContent, modifiedContent: modifiedContent, kind: file.kind, mimeType: file.mimeType, originalExists: repositoryHasHead && comparison.oldPath != nil, modifiedExists: comparison.newPath != nil, originalPreviewUrl: nil, modifiedPreviewUrl: nil)
            }
            let originalContent = comparison.oldPath.map { getRevisionContent(repoRoot: repoRoot, revision: "\(commitSha)^", path: $0) } ?? ""
            let modifiedContent = comparison.newPath.map { getRevisionContent(repoRoot: repoRoot, revision: commitSha, path: $0) } ?? ""
            return ReviewFileContents(originalContent: originalContent, modifiedContent: modifiedContent, kind: file.kind, mimeType: file.mimeType, originalExists: comparison.oldPath != nil, modifiedExists: comparison.newPath != nil, originalPreviewUrl: nil, modifiedPreviewUrl: nil)
        }

        guard let branchMergeBaseSha else { return emptyFileContents(file: file) }
        let originalContent = comparison.oldPath.map { getRevisionContent(repoRoot: repoRoot, revision: branchMergeBaseSha, path: $0) } ?? ""
        let modifiedContent = comparison.newPath.map { file.hasWorkingTreeFile ? getWorkingTreeContent(repoRoot: repoRoot, path: $0) : getRevisionContent(repoRoot: repoRoot, revision: "HEAD", path: $0) } ?? ""
        return ReviewFileContents(originalContent: originalContent, modifiedContent: modifiedContent, kind: file.kind, mimeType: file.mimeType, originalExists: comparison.oldPath != nil, modifiedExists: comparison.newPath != nil, originalPreviewUrl: nil, modifiedPreviewUrl: nil)
    }

    private static func git(_ arguments: [String], repoRoot: String, allowsFailure: Bool = false) -> String? {
        let result = runGitProcess(arguments, cwd: repoRoot)
        switch result {
        case .failure:
            return nil
        case .success(let exitCode, let stdout, _):
            guard exitCode == 0 else { return allowsFailure ? "" : nil }
            return stdout
        }
    }

    private static func runGitAllowFailure(repoRoot: String, args: [String]) -> String {
        git(args, repoRoot: repoRoot, allowsFailure: true) ?? ""
    }

    private static func runBashAllowFailure(repoRoot: String, script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", script]
        process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let capture = captureProcess(process, outputPipe: outputPipe, errorPipe: errorPipe)
        guard capture.exitCode == 0 else { return "" }
        return String(data: capture.stdout, encoding: .utf8) ?? ""
    }

    private static func runGitProcess(_ arguments: [String], cwd: String) -> GitProcessResult {
        let result = runGitProcessData(arguments, cwd: cwd)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        return .success(exitCode: result.exitCode, stdout: stdout, stderr: stderr)
    }

    private static func runGitProcessData(_ arguments: [String], cwd: String) -> GitProcessDataResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return captureProcess(process, outputPipe: outputPipe, errorPipe: errorPipe)
    }

    private static func captureProcess(_ process: Process, outputPipe: Pipe, errorPipe: Pipe) -> GitProcessDataResult {
        let group = DispatchGroup()
        var stdout = Data()
        var stderr = Data()

        do {
            try process.run()
        } catch {
            return GitProcessDataResult(exitCode: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()
        return GitProcessDataResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
