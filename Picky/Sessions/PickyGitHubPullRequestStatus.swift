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

    struct Candidate: Equatable {
        let status: PickyGitHubPullRequestStatus
        let headRefName: String
        let headRepositoryOwner: String?
    }

    struct RepositoryIdentity: Equatable {
        let host: String
        let owner: String
        let name: String

        var selector: String {
            host == "github.com" ? "\(owner)/\(name)" : "\(host)/\(owner)/\(name)"
        }

        var cacheComponent: String {
            "\(host)/\(owner)/\(name)".lowercased()
        }

        func matches(_ url: URL) -> Bool {
            guard let candidate = Self(url: url) else { return false }
            return candidate.cacheComponent == cacheComponent
        }

        init?(url: URL?) {
            guard let url,
                  let host = url.host?.lowercased(),
                  !host.isEmpty else { return nil }
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count >= 2 else { return nil }
            let owner = components[0]
            var name = components[1]
            if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
            guard !owner.isEmpty, !name.isEmpty else { return nil }
            self.host = host
            self.owner = owner
            self.name = name
        }
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

    /// `gh pr list` may make a network call, so allow more headroom than the
    /// pure-local git operations get.
    static let subprocessTimeout: TimeInterval = 6.0

    private static let cacheLock = NSLock()
    private static var cache: [String: CachedEntry] = [:]
    private static var inFlightPrefetchKeys: Set<String> = []
    /// Dedup for the cwd-only prefetch entry point. The repo/branch slot map cannot
    /// guard that entry point because resolving both values already requires running
    /// the full `PickyGitRepositoryStatus.loadSynchronously` pipeline.
    /// Without this cwd-level dedup, every `upsert(card)` would burn a fresh
    /// git+gh pipeline even when an identical prefetch is already in flight.
    private static var inFlightCwdPrefetchKeys: Set<String> = []

    static func cached(cwd: String?, repositoryURL: URL?, branch: String?) -> CachedEntry? {
        guard let key = cacheKey(cwd: cwd, repositoryURL: repositoryURL, branch: branch) else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    static func load(
        cwd: String?,
        repositoryURL: URL?,
        branch: String?,
        artifactURLs: [URL]
    ) async -> PickyGitHubPullRequestStatus? {
        let key = cacheKey(cwd: cwd, repositoryURL: repositoryURL, branch: branch)
        let status = await withCheckedContinuation { continuation in
            PickyGitRepositoryStatus.subprocessQueue.addOperation {
                continuation.resume(returning: loadSynchronously(
                    cwd: cwd,
                    repositoryURL: repositoryURL,
                    branch: branch,
                    artifactURLs: artifactURLs
                ))
            }
        }
        updateCache(status, for: key)
        return status
    }

    static func loadSynchronously(
        cwd: String?,
        repositoryURL: URL?,
        branch: String?,
        artifactURLs: [URL] = []
    ) -> PickyGitHubPullRequestStatus? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty,
              let arguments = listArguments(repositoryURL: repositoryURL, branch: branch) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedCwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        switch runGHProcess(arguments, cwd: trimmedCwd) {
        case .failure:
            return nil
        case .success(let exitCode, let stdout, _):
            guard exitCode == 0,
                  let candidates = parseCandidates(json: stdout),
                  let repository = RepositoryIdentity(url: repositoryURL) else { return nil }
            return selectCandidate(
                candidates,
                repository: repository,
                branch: branch ?? "",
                artifactURLs: artifactURLs
            )
        }
    }

    static func listArguments(repositoryURL: URL?, branch: String?) -> [String]? {
        guard let repository = RepositoryIdentity(url: repositoryURL) else { return nil }
        let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !branch.isEmpty else { return nil }
        return [
            "pr", "list",
            "--repo", repository.selector,
            "--state", "all",
            "--head", branch,
            "--limit", "20",
            "--json", "number,title,url,state,isDraft,headRefName,headRepositoryOwner",
        ]
    }

    static func parse(json: String) -> PickyGitHubPullRequestStatus? {
        struct Payload: Decodable {
            let number: Int
            let title: String
            let url: String
            let state: String
            let isDraft: Bool
        }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.url) else {
            return nil
        }
        return makeStatus(
            number: payload.number,
            title: payload.title,
            url: url,
            state: payload.state,
            isDraft: payload.isDraft
        )
    }

    static func parseCandidates(json: String) -> [Candidate]? {
        struct Payload: Decodable {
            struct Owner: Decodable {
                let login: String
            }

            let number: Int
            let title: String
            let url: String
            let state: String
            let isDraft: Bool
            let headRefName: String
            let headRepositoryOwner: Owner?
        }

        guard let data = json.data(using: .utf8),
              let payloads = try? JSONDecoder().decode([Payload].self, from: data) else { return nil }
        return payloads.compactMap { payload in
            guard let url = URL(string: payload.url) else { return nil }
            return Candidate(
                status: makeStatus(
                    number: payload.number,
                    title: payload.title,
                    url: url,
                    state: payload.state,
                    isDraft: payload.isDraft
                ),
                headRefName: payload.headRefName,
                headRepositoryOwner: payload.headRepositoryOwner?.login
            )
        }
    }

    static func selectCandidate(
        _ candidates: [Candidate],
        repository: RepositoryIdentity,
        branch: String,
        artifactURLs: [URL]
    ) -> PickyGitHubPullRequestStatus? {
        let matching = candidates.filter { candidate in
            candidate.headRefName == branch && repository.matches(candidate.status.url)
        }
        if matching.count == 1 { return matching[0].status }

        let sameOwner = matching.filter { candidate in
            candidate.headRepositoryOwner?.caseInsensitiveCompare(repository.owner) == .orderedSame
        }
        let activeSameOwner = sameOwner.filter { candidate in
            candidate.status.state == .open || candidate.status.state == .draft
        }
        if activeSameOwner.count == 1 { return activeSameOwner[0].status }

        let artifactURLKeys = Set(artifactURLs.map(normalizedURLKey))
        let artifactMatches = matching.filter { artifactURLKeys.contains(normalizedURLKey($0.status.url)) }
        if artifactMatches.count == 1 { return artifactMatches[0].status }
        if sameOwner.count == 1 { return sameOwner[0].status }
        return nil
    }

    private static func makeStatus(
        number: Int,
        title: String,
        url: URL,
        state: String,
        isDraft: Bool
    ) -> PickyGitHubPullRequestStatus {
        PickyGitHubPullRequestStatus(
            number: number,
            title: title,
            url: url,
            state: mapState(rawState: state, isDraft: isDraft)
        )
    }

    private static func normalizedURLKey(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return (components?.url ?? url).absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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

    static func prefetchIfNeeded(
        cwd: String?,
        repositoryURL: URL?,
        branch: String?,
        artifactURLs: [URL]
    ) {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        guard let key = cacheKey(cwd: cwd, repositoryURL: repositoryURL, branch: branch) else { return }
        guard claimPrefetchSlot(for: key) else { return }

        PickyGitRepositoryStatus.subprocessQueue.addOperation {
            let status = loadSynchronously(
                cwd: cwd,
                repositoryURL: repositoryURL,
                branch: branch,
                artifactURLs: artifactURLs
            )
            releasePrefetchSlot(for: key)
            updateCache(status, for: key)
        }
    }

    /// Prefetch the PR by first resolving the current repository and branch from `cwd`.
    /// Used by the session list so that a never-visited session can paint the PR badge
    /// from cache on the very first HUD render after the session loads.
    static func prefetchIfNeeded(cwd: String?, artifactURLs: [URL]) {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty else { return }
        let cwdKey = URL(fileURLWithPath: trimmedCwd).standardizedFileURL.path
        guard claimCwdPrefetchSlot(for: cwdKey) else { return }

        PickyGitRepositoryStatus.subprocessQueue.addOperation {
            defer { releaseCwdPrefetchSlot(for: cwdKey) }
            let git: PickyGitRepositoryStatus
            if let cachedGit = PickyGitRepositoryStatus.cached(cwd: trimmedCwd) {
                git = cachedGit
            } else if let loadedGit = PickyGitRepositoryStatus.loadSynchronously(cwd: trimmedCwd) {
                git = loadedGit
            } else {
                return
            }
            guard let key = cacheKey(cwd: trimmedCwd, repositoryURL: git.remoteWebURL, branch: git.branchName),
                  claimPrefetchSlot(for: key) else { return }
            let status = loadSynchronously(
                cwd: trimmedCwd,
                repositoryURL: git.remoteWebURL,
                branch: git.branchName,
                artifactURLs: artifactURLs
            )
            releasePrefetchSlot(for: key)
            updateCache(status, for: key)
        }
    }

    static func invalidateCache(cwd: String?, repositoryURL: URL?, branch: String?) {
        guard let key = cacheKey(cwd: cwd, repositoryURL: repositoryURL, branch: branch) else { return }
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

    static func cacheKey(cwd: String?, repositoryURL: URL?, branch: String?) -> String? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty,
              !trimmedBranch.isEmpty,
              let repository = RepositoryIdentity(url: repositoryURL) else { return nil }
        let normalizedCwd = URL(fileURLWithPath: trimmedCwd).standardizedFileURL.path
        return "\(normalizedCwd)#\(repository.cacheComponent)#\(trimmedBranch)"
    }

    private static func runGHProcess(_ arguments: [String], cwd: String) -> PickyGitRepositoryStatus.GitProcessResult {
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

        return PickyGitRepositoryStatus.runProcessWithTimeout(
            process,
            timeout: subprocessTimeout,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        )
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

    private static func claimCwdPrefetchSlot(for cwdKey: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if inFlightCwdPrefetchKeys.contains(cwdKey) {
            return false
        }
        inFlightCwdPrefetchKeys.insert(cwdKey)
        return true
    }

    private static func releaseCwdPrefetchSlot(for cwdKey: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        inFlightCwdPrefetchKeys.remove(cwdKey)
    }
}
