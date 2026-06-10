//
//  PickyFullscreenBranchDiffProvider.swift
//  Picky
//
//  Resolves fullscreen 변경사항 from branch base plus uncommitted changes.
//

import Foundation

@MainActor
final class PickyFullscreenBranchDiffProvider {
    typealias GitRunner = @Sendable (_ arguments: [String], _ cwd: String) async -> String?

    struct BranchDiff: Equatable {
        let repositoryRoot: String
        let baseRef: String?
        let mergeBaseRef: String?
        let headRef: String
        let dirtyDigest: String
        let totalInsertions: Int
        let totalDeletions: Int
        let files: [File]
    }

    struct File: Equatable, Identifiable {
        let path: String
        let status: String
        let insertions: Int
        let deletions: Int
        let hasCommittedChanges: Bool
        let hasWorkingTreeChanges: Bool

        var id: String { path }
    }

    private struct MutableFile {
        var path: String
        var status: String = "modified"
        var insertions: Int = 0
        var deletions: Int = 0
        var hasCommittedChanges = false
        var hasWorkingTreeChanges = false
    }

    let cwd: String
    private let gitRunner: GitRunner
    private var cachedSummary: BranchDiff?
    private var diffCache: [String: String?] = [:]

    init(
        cwd: String,
        gitRunner: @escaping GitRunner = { arguments, cwd in await PickyFullscreenBranchDiffProvider.runGit(arguments: arguments, cwd: cwd) }
    ) {
        self.cwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gitRunner = gitRunner
    }

    func fetchSummary() async -> BranchDiff? {
        if let cachedSummary { return cachedSummary }
        guard !cwd.isEmpty,
              let repositoryRoot = (await gitRunner(["rev-parse", "--show-toplevel"], cwd))?.trimmedNonEmpty,
              let headRef = (await gitRunner(["rev-parse", "HEAD"], cwd))?.trimmedNonEmpty else {
            cachedSummary = nil
            return nil
        }

        let dirtyDigest = await gitRunner(["status", "--porcelain=v1"], cwd) ?? ""
        let baseRef = await resolveBaseRef(cwd: cwd)
        let mergeBaseRef: String?
        if let baseRef {
            mergeBaseRef = (await gitRunner(["merge-base", baseRef, "HEAD"], cwd))?.trimmedNonEmpty
        } else {
            mergeBaseRef = nil
        }

        var files: [String: MutableFile] = [:]
        if let mergeBaseRef {
            let range = "\(mergeBaseRef)..HEAD"
            merge(
                numstat: await gitRunner(["diff", "--numstat", range], cwd) ?? "",
                nameStatus: await gitRunner(["diff", "--name-status", range], cwd) ?? "",
                source: .committed,
                into: &files
            )
        }
        merge(
            numstat: await gitRunner(["diff", "--numstat"], cwd) ?? "",
            nameStatus: await gitRunner(["diff", "--name-status"], cwd) ?? "",
            source: .workingTree,
            into: &files
        )

        let sortedFiles = files.values
            .sorted { lhs, rhs in lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending }
            .map {
                File(
                    path: $0.path,
                    status: $0.status,
                    insertions: $0.insertions,
                    deletions: $0.deletions,
                    hasCommittedChanges: $0.hasCommittedChanges,
                    hasWorkingTreeChanges: $0.hasWorkingTreeChanges
                )
            }
        let summary = BranchDiff(
            repositoryRoot: repositoryRoot,
            baseRef: baseRef,
            mergeBaseRef: mergeBaseRef,
            headRef: headRef,
            dirtyDigest: dirtyDigest,
            totalInsertions: sortedFiles.reduce(0) { $0 + $1.insertions },
            totalDeletions: sortedFiles.reduce(0) { $0 + $1.deletions },
            files: sortedFiles
        )
        cachedSummary = summary
        return summary
    }

    func fetchDiff(path: String) async -> String? {
        if let cached = diffCache[path] { return cached }
        guard let summary = await fetchSummary(), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diffCache[path] = nil
            return nil
        }
        guard let file = summary.files.first(where: { $0.path == path }) else {
            diffCache[path] = nil
            return nil
        }

        var sections: [String] = []
        if file.hasCommittedChanges, let mergeBaseRef = summary.mergeBaseRef {
            if let diff = (await gitRunner(["diff", "\(mergeBaseRef)..HEAD", "--", path], cwd))?.trimmedNonEmpty {
                sections.append("# Branch changes (\(summary.baseRef ?? mergeBaseRef)..HEAD)\n\(diff)")
            }
        }
        if file.hasWorkingTreeChanges {
            if let diff = (await gitRunner(["diff", "--", path], cwd))?.trimmedNonEmpty {
                sections.append("# Working tree changes\n\(diff)")
            }
        }

        let combined = sections.isEmpty ? nil : sections.joined(separator: "\n\n")
        diffCache[path] = combined
        return combined
    }

    private func resolveBaseRef(cwd: String) async -> String? {
        if let originHead = (await gitRunner(["symbolic-ref", "refs/remotes/origin/HEAD"], cwd))?.trimmedNonEmpty {
            return originHead
        }
        for fallback in ["origin/main", "origin/master", "origin/develop"] {
            if (await gitRunner(["rev-parse", "--verify", fallback], cwd))?.trimmedNonEmpty != nil {
                return fallback
            }
        }
        return nil
    }

    private enum Source {
        case committed
        case workingTree
    }

    private func merge(numstat: String, nameStatus: String, source: Source, into files: inout [String: MutableFile]) {
        let stats = Self.parseNumstat(numstat)
        let statuses = Self.parseNameStatus(nameStatus)
        for (path, stat) in stats {
            var file = files[path] ?? MutableFile(path: path)
            file.insertions += stat.insertions
            file.deletions += stat.deletions
            file.status = Self.strongerStatus(file.status, statuses[path] ?? "modified")
            switch source {
            case .committed:
                file.hasCommittedChanges = true
            case .workingTree:
                file.hasWorkingTreeChanges = true
            }
            files[path] = file
        }
        for (path, status) in statuses where files[path] == nil {
            var file = MutableFile(path: path)
            file.status = status
            switch source {
            case .committed:
                file.hasCommittedChanges = true
            case .workingTree:
                file.hasWorkingTreeChanges = true
            }
            files[path] = file
        }
    }

    nonisolated static func parseNumstat(_ output: String) -> [String: PickyFullscreenFileDiffProvider.Numstat] {
        output.split(whereSeparator: { $0.isNewline }).reduce(into: [:]) { result, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let insertions = Int(fields[0]),
                  let deletions = Int(fields[1]) else { return }
            let path = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            result[path] = PickyFullscreenFileDiffProvider.Numstat(insertions: insertions, deletions: deletions)
        }
    }

    nonisolated static func parseNameStatus(_ output: String) -> [String: String] {
        output.split(whereSeparator: { $0.isNewline }).reduce(into: [:]) { result, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return }
            let rawStatus = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pathIndex = rawStatus.uppercased().hasPrefix("R") || rawStatus.uppercased().hasPrefix("C") ? min(2, fields.count - 1) : 1
            let path = String(fields[pathIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            result[path] = normalizedStatus(rawStatus)
        }
    }

    nonisolated private static func normalizedStatus(_ rawStatus: String) -> String {
        switch rawStatus.uppercased().first {
        case "A": "added"
        case "M": "modified"
        case "D": "deleted"
        case "R": "renamed"
        case "C": "copied"
        default: rawStatus
        }
    }

    nonisolated private static func strongerStatus(_ lhs: String, _ rhs: String) -> String {
        func rank(_ status: String) -> Int {
            switch status.lowercased() {
            case "deleted", "d", "removed": 4
            case "renamed", "r": 3
            case "added", "a", "new": 2
            case "modified", "m", "changed": 1
            default: 0
            }
        }
        return rank(rhs) > rank(lhs) ? rhs : lhs
    }

    private static func runGit(arguments: [String], cwd: String) async -> String? {
        await withCheckedContinuation { continuation in
            PickyGitRepositoryStatus.subprocessQueue.addOperation {
                continuation.resume(returning: runGitSynchronously(arguments: arguments, cwd: cwd))
            }
        }
    }

    nonisolated private static func runGitSynchronously(arguments: [String], cwd: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let process = Process()
        PickyGitRepositoryStatus.configureBackgroundGitProbeProcess(process, arguments: arguments, cwd: cwd)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        switch PickyGitRepositoryStatus.runProcessWithTimeout(
            process,
            timeout: PickyGitRepositoryStatus.subprocessTimeout,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        ) {
        case .success(let exitCode, let stdout, _):
            return exitCode == 0 ? stdout : nil
        case .failure:
            return nil
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
