//
//  PickyGitRepositoryStatus.swift
//  Picky
//
//  Lightweight git metadata used by the Pickle HUD cards.
//

import Foundation

struct PickyGitRepositoryStatus: Equatable {
    private static let statusCacheLock = NSLock()
    private static var statusCache: [String: PickyGitRepositoryStatus] = [:]
    private static var inFlightPrefetchKeys: Set<String> = []

    /// Dedicated queue for blocking *background* git/gh subprocess invocations
    /// (HUD status probes, prefetches). Keeping these off Swift's cooperative
    /// pool prevents `Process.waitUntilExit()` from starving the global async
    /// runtime when many Pickles refresh simultaneously. A 2025-05 spin sample
    /// caught 10 cooperative-pool threads stuck in `waitUntilExit`, blocking
    /// MainActor continuations and tripping the main-thread watchdog.
    /// `maxConcurrentOperationCount = 2` lets two repos refresh in parallel
    /// while leaving the cooperative pool free for SwiftUI and daemon I/O work;
    /// `PickyGitHubPullRequestStatus` shares this queue so the cap covers both
    /// `git` and `gh` metadata invocations.
    static let subprocessQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.jonghakseo.picky.git-subprocess"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    /// Dedicated queue for *user-initiated* git commands (push, pull, etc.).
    /// Kept separate from `subprocessQueue` so a deep prefetch backlog cannot
    /// delay something the user just clicked, and so the longer
    /// `userInitiatedSubprocessTimeout` cannot stall background status work.
    static let userInitiatedSubprocessQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.jonghakseo.picky.git-subprocess.user"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    /// Per-subprocess wall-clock budget for *background metadata probes*.
    /// Anything longer is almost always a hung pre-commit hook, lfs lock, or
    /// filter that we should not block on. 5s gives slow monorepos / cold
    /// filesystem caches enough headroom to avoid false-negative HUD blanking
    /// while still bounding the queue-slot hold time.
    static let subprocessTimeout: TimeInterval = 5.0

    /// Per-subprocess wall-clock budget for *user-initiated* git commands like
    /// `git push` / `git pull`. These can legitimately take minutes on slow
    /// networks, initial pushes, LFS uploads, or large pulls, so the
    /// metadata-probe budget would falsely kill them. 5 minutes covers the
    /// realistic worst case while still preventing an infinitely-stuck SSH
    /// auth prompt or filter from pinning a queue slot forever.
    static let userInitiatedSubprocessTimeout: TimeInterval = 300.0

    /// Environment for background git metadata probes. Git documents
    /// `GIT_OPTIONAL_LOCKS=0` as the way for background processes to avoid
    /// optional lock-taking side effects, notably `git status` refreshing the
    /// index and contending with foreground git commands.
    static func backgroundGitProbeEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    static func configureBackgroundGitProbeProcess(_ process: Process, arguments: [String], cwd: String) {
        configureGitProcess(process, arguments: arguments, cwd: cwd, disablesOptionalLocks: true)
    }

    private static func configureGitProcess(
        _ process: Process,
        arguments: [String],
        cwd: String,
        disablesOptionalLocks: Bool
    ) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + arguments
        if disablesOptionalLocks {
            process.environment = backgroundGitProbeEnvironment()
        }
    }

    let repositoryName: String
    let branchName: String
    let hasUncommittedChanges: Bool
    let insertions: Int
    let deletions: Int
    let aheadCount: Int
    let behindCount: Int
    let remoteWebURL: URL?
    let branchWebURL: URL?

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
        let status = await withCheckedContinuation { continuation in
            subprocessQueue.addOperation {
                continuation.resume(returning: loadSynchronously(cwd: cwd))
            }
        }
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

        let remoteWebURL = remoteWebURLForOrigin(cwd: trimmedCwd)
        let repositoryName = remoteWebURL.flatMap(remoteRepositoryName(from:)) ?? URL(fileURLWithPath: topLevel).lastPathComponent
        let branchName = currentBranchName(cwd: trimmedCwd)
        let branchWebURL = remoteWebURL.flatMap { makeBranchWebURL(remoteWebURL: $0, branchName: branchName) }
        let statusOutput = git(["status", "--porcelain"], cwd: trimmedCwd) ?? ""
        let diffStats = parseNumstat(git(["diff", "--numstat", "HEAD", "--"], cwd: trimmedCwd, allowsFailure: true) ?? "")
        let untrackedInsertions = countUntrackedTextLines(cwd: trimmedCwd, topLevel: topLevel)
        let position = parseAheadBehind(git(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], cwd: trimmedCwd, allowsFailure: true) ?? "")

        return PickyGitRepositoryStatus(
            repositoryName: repositoryName,
            branchName: branchName,
            hasUncommittedChanges: !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            insertions: diffStats.insertions + untrackedInsertions,
            deletions: diffStats.deletions,
            aheadCount: position.ahead,
            behindCount: position.behind,
            remoteWebURL: remoteWebURL,
            branchWebURL: branchWebURL
        )
    }

    /// Maximum number of untracked files to scan per `loadSynchronously` call. Above this we
    /// silently truncate so a worktree with thousands of stray build artifacts does not block
    /// the HUD git refresh.
    static let maxUntrackedFilesScanned = 500

    /// Cap each untracked file read at 1 MB. Anything larger is skipped — these are
    /// almost always generated/binary content and not what the +/- pill is trying to surface.
    static let maxUntrackedFileBytes = 1 * 1024 * 1024

    static func countUntrackedTextLines(cwd: String, topLevel: String) -> Int {
        let raw = git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: cwd, allowsFailure: true) ?? ""
        let paths = parseNullSeparatedPaths(raw).prefix(maxUntrackedFilesScanned)
        var total = 0
        for relativePath in paths {
            let absolute = (topLevel as NSString).appendingPathComponent(relativePath)
            if let count = textFileLineCount(at: absolute) {
                total += count
            }
        }
        return total
    }

    static func parseNullSeparatedPaths(_ output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// Returns the number of lines in `path` matching `git diff --numstat` semantics, or
    /// `nil` when the file is binary, unreadable, or exceeds `maxUntrackedFileBytes`.
    static func textFileLineCount(at path: String) -> Int? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var newlineCount = 0
        var lastByte: UInt8 = 0
        var hasContent = false
        var totalBytes = 0

        while totalBytes < maxUntrackedFileBytes,
              let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if chunk.contains(0) { return nil }
            hasContent = true
            totalBytes += chunk.count
            for byte in chunk where byte == 0x0A {
                newlineCount += 1
            }
            if let last = chunk.last { lastByte = last }
        }

        // Treat a trailing line without a newline as a line, matching how git counts
        // additions for files lacking a final newline.
        if hasContent && lastByte != 0x0A {
            newlineCount += 1
        }
        return newlineCount
    }

    static func makeBranchWebURL(remoteWebURL: URL, branchName: String) -> URL? {
        let trimmedBranchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranchName.isEmpty else { return nil }
        return remoteWebURL
            .appendingPathComponent("tree", isDirectory: true)
            .appendingPathComponent(trimmedBranchName, isDirectory: false)
    }

    private static func remoteWebURLForOrigin(cwd: String) -> URL? {
        let raw = git(["remote", "get-url", "origin"], cwd: cwd, allowsFailure: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return convertRemoteURLToWeb(raw)
    }

    static func remoteRepositoryName(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
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

    enum GitProcessResult {
        case success(exitCode: Int32, stdout: String, stderr: String)
        case failure(message: String)
    }

    private static func runGitProcess(
        _ arguments: [String],
        cwd: String,
        timeout: TimeInterval = subprocessTimeout,
        disablesOptionalLocks: Bool = true
    ) -> GitProcessResult {
        let process = Process()
        configureGitProcess(process, arguments: arguments, cwd: cwd, disablesOptionalLocks: disablesOptionalLocks)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return runProcessWithTimeout(process, timeout: timeout, outputPipe: outputPipe, errorPipe: errorPipe)
    }

    /// Runs `process` with `terminationHandler`-driven completion and a wall-clock
    /// timeout. On timeout the child is sent `SIGTERM`, then `SIGKILL` if it does
    /// not exit promptly, so a hung subprocess cannot pin a queue slot.
    ///
    /// Pipes are drained concurrently on background queues so a child that
    /// produces more output than the pipe buffer (~64 KB) — e.g.
    /// `git status --porcelain` in a repo with thousands of dirty files — does
    /// not deadlock writing into a full buffer and falsely look like a timeout.
    ///
    /// Internal so `PickyGitHubPullRequestStatus.runGHProcess` can reuse the same
    /// timeout + drain semantics for `gh`.
    static func runProcessWithTimeout(_ process: Process, timeout: TimeInterval, outputPipe: Pipe, errorPipe: Pipe) -> GitProcessResult {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return .failure(message: error.localizedDescription)
        }

        // Drain stdout/stderr on background queues so the child cannot block
        // on a full pipe buffer waiting for us to read. Reads return EOF once
        // the child exits (or is killed) and the kernel closes the write-end.
        let drainGroup = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        let readQueue = DispatchQueue.global(qos: .utility)
        drainGroup.enter()
        readQueue.async {
            stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        readQueue.async {
            stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 0.5)
            }
            // Give the drain reads a moment to observe EOF naturally after the
            // kernel closes the child's pipe write-end.
            if drainGroup.wait(timeout: .now() + 0.5) == .timedOut {
                // A grandchild (ssh helper, filter, hook daemon) may have
                // inherited stdout/stderr and is holding the write-end open,
                // so `readDataToEndOfFile` will never see EOF on its own.
                // Force-close our read-end to interrupt the blocked reads;
                // otherwise each timed-out subprocess leaks a GCD utility
                // thread + Pipe/Data heap and we eventually reproduce the
                // exact thread-exhaustion this patch is meant to prevent.
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                _ = drainGroup.wait(timeout: .now() + 0.1)
            }
            let argsForMessage = (process.arguments ?? []).joined(separator: " ")
            return .failure(message: "subprocess timed out after \(timeout)s: \(argsForMessage)")
        }

        // Process exited cleanly — drain reads should resolve near-instantly
        // because the kernel has closed the write-end of both pipes.
        drainGroup.wait()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return .success(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    struct GitCommandOutcome: Equatable {
        let exitCode: Int32
        let combinedOutput: String
        var isSuccess: Bool { exitCode == 0 }
    }

    static func runCommand(_ arguments: [String], cwd: String) async -> GitCommandOutcome {
        await withCheckedContinuation { continuation in
            userInitiatedSubprocessQueue.addOperation {
                let outcome: GitCommandOutcome
                switch runGitProcess(
                    arguments,
                    cwd: cwd,
                    timeout: userInitiatedSubprocessTimeout,
                    disablesOptionalLocks: false
                ) {
                case .failure(let message):
                    outcome = GitCommandOutcome(exitCode: -1, combinedOutput: message)
                case .success(let exitCode, let stdout, let stderr):
                    let combined = [stderr, stdout]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    outcome = GitCommandOutcome(exitCode: exitCode, combinedOutput: combined)
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Warm the cache for `cwd` so the HUD can render git context on the very first card paint.
    /// No-ops when the cache already has a value or when an identical prefetch is in flight.
    static func prefetchIfNeeded(cwd: String?) {
        guard let cacheKey = cacheKey(cwd: cwd) else { return }
        guard claimPrefetchSlot(for: cacheKey) else { return }

        subprocessQueue.addOperation {
            let status = loadSynchronously(cwd: cwd)
            releasePrefetchSlot(for: cacheKey)
            updateCache(status, for: cacheKey)
        }
    }

    private static func claimPrefetchSlot(for cacheKey: String) -> Bool {
        statusCacheLock.lock()
        defer { statusCacheLock.unlock() }
        if statusCache[cacheKey] != nil || inFlightPrefetchKeys.contains(cacheKey) {
            return false
        }
        inFlightPrefetchKeys.insert(cacheKey)
        return true
    }

    private static func releasePrefetchSlot(for cacheKey: String) {
        statusCacheLock.lock()
        defer { statusCacheLock.unlock() }
        inFlightPrefetchKeys.remove(cacheKey)
    }

    static func invalidateCache(cwd: String?) {
        guard let cacheKey = cacheKey(cwd: cwd) else { return }
        statusCacheLock.lock()
        defer { statusCacheLock.unlock() }
        statusCache.removeValue(forKey: cacheKey)
    }
}
