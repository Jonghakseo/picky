//
//  PickyGitHubPullRequestStatus.swift
//  Picky
//
//  Resolves the GitHub pull request associated with the current branch via the `gh` CLI.
//

import Foundation

struct PickyGitHubPullRequestStatus: Equatable {
    enum State: String, Equatable {
        case draft
        case open
        case merged
        case closed
    }

    let number: Int
    let title: String
    let url: URL
    let state: State

    static let staleAfter: TimeInterval = 300

    struct CachedEntry: Equatable {
        let status: PickyGitHubPullRequestStatus?
        let fetchedAt: Date

        func isStale(now: Date = Date(), ttl: TimeInterval = PickyGitHubPullRequestStatus.staleAfter) -> Bool {
            now.timeIntervalSince(fetchedAt) > ttl
        }
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CachedEntry] = [:]
    private static var inFlightPrefetchKeys: Set<String> = []

    static func cached(cwd: String?, branch: String?) -> CachedEntry? {
        guard let key = cacheKey(cwd: cwd, branch: branch) else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    static func load(cwd: String?, branch: String?) async -> PickyGitHubPullRequestStatus? {
        let key = cacheKey(cwd: cwd, branch: branch)
        let status = await Task.detached(priority: .utility) {
            loadSynchronously(cwd: cwd)
        }.value
        updateCache(status, for: key)
        return status
    }

    static func loadSynchronously(cwd: String?) -> PickyGitHubPullRequestStatus? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedCwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        switch runGHProcess(["pr", "view", "--json", "number,title,url,state,isDraft"], cwd: trimmedCwd) {
        case .failure:
            return nil
        case .success(let exitCode, let stdout, _):
            guard exitCode == 0 else { return nil }
            return parse(json: stdout)
        }
    }

    static func parse(json: String) -> PickyGitHubPullRequestStatus? {
        guard let data = json.data(using: .utf8) else { return nil }
        struct Payload: Decodable {
            let number: Int
            let title: String
            let url: String
            let state: String
            let isDraft: Bool
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.url) else {
            return nil
        }
        return PickyGitHubPullRequestStatus(
            number: payload.number,
            title: payload.title,
            url: url,
            state: mapState(rawState: payload.state, isDraft: payload.isDraft)
        )
    }

    static func mapState(rawState: String, isDraft: Bool) -> State {
        switch rawState.uppercased() {
        case "OPEN":
            return isDraft ? .draft : .open
        case "MERGED":
            return .merged
        case "CLOSED":
            return .closed
        default:
            return .closed
        }
    }

    static func prefetchIfNeeded(cwd: String?, branch: String?) {
        guard let key = cacheKey(cwd: cwd, branch: branch) else { return }
        guard claimPrefetchSlot(for: key) else { return }

        Task.detached(priority: .utility) {
            let status = loadSynchronously(cwd: cwd)
            releasePrefetchSlot(for: key)
            updateCache(status, for: key)
        }
    }

    static func invalidateCache(cwd: String?, branch: String?) {
        guard let key = cacheKey(cwd: cwd, branch: branch) else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: key)
    }

    private static func updateCache(_ status: PickyGitHubPullRequestStatus?, for key: String?) {
        guard let key else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = CachedEntry(status: status, fetchedAt: Date())
    }

    private static func cacheKey(cwd: String?, branch: String?) -> String? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty else { return nil }
        let normalizedCwd = URL(fileURLWithPath: trimmedCwd).standardizedFileURL.path
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(normalizedCwd)#\(trimmedBranch)"
    }

    private enum GHProcessResult {
        case success(exitCode: Int32, stdout: String, stderr: String)
        case failure(message: String)
    }

    private static func runGHProcess(_ arguments: [String], cwd: String) -> GHProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Extend PATH so the user's `gh` (typically /opt/homebrew/bin or /usr/local/bin) is reachable
        // even when the app is launched from Finder with a minimal environment.
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = existingPath.isEmpty ? extraPath : "\(existingPath):\(extraPath)"
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.arguments = ["gh"] + arguments

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

    private static func claimPrefetchSlot(for key: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache[key] != nil || inFlightPrefetchKeys.contains(key) {
            return false
        }
        inFlightPrefetchKeys.insert(key)
        return true
    }

    private static func releasePrefetchSlot(for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        inFlightPrefetchKeys.remove(key)
    }
}
