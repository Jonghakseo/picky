//
//  PickyGitRepositoryStatus.swift
//  Picky
//
//  Lightweight git metadata used by the side-agent HUD cards.
//

import Foundation

struct PickyGitRepositoryStatus: Equatable {
    private static let statusCacheLock = NSLock()
    private static var statusCache: [String: PickyGitRepositoryStatus] = [:]

    let repositoryName: String
    let branchName: String
    let hasUncommittedChanges: Bool
    let insertions: Int
    let deletions: Int
    let aheadCount: Int
    let behindCount: Int
    let remoteWebURL: URL?

    var repositoryDisplayName: String {
        repositoryName
    }

    var branchDisplayName: String {
        hasUncommittedChanges ? "\(branchName)*" : branchName
    }

    var hasVisibleMetrics: Bool {
        insertions > 0 || deletions > 0 || aheadCount > 0 || behindCount > 0
    }

    static func cached(cwd: String?) -> PickyGitRepositoryStatus? {
        guard let cacheKey = cacheKey(cwd: cwd) else { return nil }
        statusCacheLock.lock()
        defer { statusCacheLock.unlock() }
        return statusCache[cacheKey]
    }

    static func load(cwd: String?) async -> PickyGitRepositoryStatus? {
        let cacheKey = cacheKey(cwd: cwd)
        let status = await Task.detached(priority: .utility) {
            loadSynchronously(cwd: cwd)
        }.value
        updateCache(status, for: cacheKey)
        return status
    }

    static func loadSynchronously(cwd: String?) -> PickyGitRepositoryStatus? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedCwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        guard git(["rev-parse", "--is-inside-work-tree"], cwd: trimmedCwd)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true",
              let topLevel = git(["rev-parse", "--show-toplevel"], cwd: trimmedCwd)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !topLevel.isEmpty else {
            return nil
        }

        let repositoryName = URL(fileURLWithPath: topLevel).lastPathComponent
        let branchName = currentBranchName(cwd: trimmedCwd)
        let statusOutput = git(["status", "--porcelain"], cwd: trimmedCwd) ?? ""
        let diffStats = parseNumstat(git(["diff", "--numstat", "HEAD", "--"], cwd: trimmedCwd, allowsFailure: true) ?? "")
        let position = parseAheadBehind(git(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], cwd: trimmedCwd, allowsFailure: true) ?? "")
        let remoteWebURL = remoteWebURLForOrigin(cwd: trimmedCwd)

        return PickyGitRepositoryStatus(
            repositoryName: repositoryName,
            branchName: branchName,
            hasUncommittedChanges: !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            insertions: diffStats.insertions,
            deletions: diffStats.deletions,
            aheadCount: position.ahead,
            behindCount: position.behind,
            remoteWebURL: remoteWebURL
        )
    }

    private static func remoteWebURLForOrigin(cwd: String) -> URL? {
        let raw = git(["remote", "get-url", "origin"], cwd: cwd, allowsFailure: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return convertRemoteURLToWeb(raw)
    }

    static func convertRemoteURLToWeb(_ raw: String) -> URL? {
        var value = raw
        if value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix(".git") { value.removeLast(4) }
        // SSH form: git@host:user/repo or git@host:user/repo.git
        if let atIndex = value.firstIndex(of: "@"), value.contains(":") {
            let prefix = value[..<atIndex]
            // git@ or any user@ — only treat as SSH if the segment after `@` has `:path` form,
            // not a port number. We detect SSH by `host:path` pattern (path starts with letter).
            if !prefix.isEmpty {
                let hostAndPath = value[value.index(after: atIndex)...]
                if let colonIndex = hostAndPath.firstIndex(of: ":") {
                    let host = String(hostAndPath[..<colonIndex])
                    let path = String(hostAndPath[hostAndPath.index(after: colonIndex)...])
                    let firstPathChar = path.first
                    if firstPathChar?.isLetter == true || firstPathChar == "_" || firstPathChar == "~" {
                        return URL(string: "https://\(host)/\(path)")
                    }
                }
            }
        }
        // ssh://git@host/path
        if value.lowercased().hasPrefix("ssh://") {
            let stripped = value.dropFirst("ssh://".count)
            let withoutUser = stripped.split(separator: "@", maxSplits: 1).last.map(String.init) ?? String(stripped)
            return URL(string: "https://\(withoutUser)")
        }
        // https://, http://, git://
        if let url = URL(string: value), let scheme = url.scheme?.lowercased() {
            if scheme == "https" || scheme == "http" {
                return url
            }
            if scheme == "git" {
                let stripped = value.dropFirst("git://".count)
                return URL(string: "https://\(stripped)")
            }
        }
        return nil
    }

    static func parseNumstat(_ output: String) -> (insertions: Int, deletions: Int) {
        output.split(whereSeparator: { $0.isNewline }).reduce(into: (insertions: 0, deletions: 0)) { result, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2,
                  let insertions = Int(fields[0]),
                  let deletions = Int(fields[1]) else { return }
            result.insertions += insertions
            result.deletions += deletions
        }
    }

    static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int) {
        let fields = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard fields.count >= 2,
              let behind = Int(fields[0]),
              let ahead = Int(fields[1]) else {
            return (ahead: 0, behind: 0)
        }
        return (ahead: ahead, behind: behind)
    }

    private static func updateCache(_ status: PickyGitRepositoryStatus?, for cacheKey: String?) {
        guard let cacheKey else { return }
        statusCacheLock.lock()
        defer { statusCacheLock.unlock() }
        if let status {
            statusCache[cacheKey] = status
        } else {
            statusCache.removeValue(forKey: cacheKey)
        }
    }

    private static func cacheKey(cwd: String?) -> String? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmedCwd).standardizedFileURL.path
    }

    private static func currentBranchName(cwd: String) -> String {
        let branch = git(["branch", "--show-current"], cwd: cwd)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !branch.isEmpty { return branch }
        let shortHash = git(["rev-parse", "--short", "HEAD"], cwd: cwd, allowsFailure: true)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return shortHash.isEmpty ? "detached" : shortHash
    }

    private static func git(_ arguments: [String], cwd: String, allowsFailure: Bool = false) -> String? {
        let result = runGitProcess(arguments, cwd: cwd)
        switch result {
        case .failure:
            return nil
        case .success(let exitCode, let stdout, _):
            guard exitCode == 0 || allowsFailure else { return nil }
            return stdout
        }
    }

    private enum GitProcessResult {
        case success(exitCode: Int32, stdout: String, stderr: String)
        case failure(message: String)
    }

    private static func runGitProcess(_ arguments: [String], cwd: String) -> GitProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(message: error.localizedDescription)
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return .success(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    struct GitCommandOutcome: Equatable {
        let exitCode: Int32
        let combinedOutput: String
        var isSuccess: Bool { exitCode == 0 }
    }

    static func runCommand(_ arguments: [String], cwd: String) async -> GitCommandOutcome {
        await Task.detached(priority: .userInitiated) {
            switch runGitProcess(arguments, cwd: cwd) {
            case .failure(let message):
                return GitCommandOutcome(exitCode: -1, combinedOutput: message)
            case .success(let exitCode, let stdout, let stderr):
                let combined = [stderr, stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return GitCommandOutcome(exitCode: exitCode, combinedOutput: combined)
            }
        }.value
    }

    static func invalidateCache(cwd: String?) {
        guard let cacheKey = cacheKey(cwd: cwd) else { return }
        statusCacheLock.lock()
        defer { statusCacheLock.unlock() }
        statusCache.removeValue(forKey: cacheKey)
    }
}
