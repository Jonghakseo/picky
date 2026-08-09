//
//  PickyGitRepositoryStatusTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyGitRepositoryStatusTests {
    @Test func refreshPolicyOnlyAutoRefreshesCompletedSessions() {
        #expect(PickyGitContextRefreshPolicy.shouldAutoRefreshGit(for: .completed) == true)
        #expect(PickyGitContextRefreshPolicy.shouldAutoRefreshGit(for: .running) == false)
        #expect(PickyGitContextRefreshPolicy.shouldAutoRefreshGit(for: .queued) == false)
        #expect(PickyGitContextRefreshPolicy.shouldAutoRefreshGit(for: .waiting_for_input) == false)
        #expect(PickyGitContextRefreshPolicy.shouldAutoRefreshGit(for: .blocked) == false)
        #expect(PickyGitContextRefreshPolicy.shouldAutoRefreshGit(for: .failed) == false)
        #expect(PickyGitContextRefreshPolicy.shouldAutoRefreshGit(for: .cancelled) == false)
    }

    @Test func refreshCacheReusesFreshValueUntilTTLExpires() async throws {
        let clock = TestGitStatusClock(now: 100)
        let loader = ManualGitStatusLoader()
        let cache = PickyGitRepositoryStatusRefreshCache(clock: { clock.value }) { cwd in
            await loader.load(cwd: cwd)
        }
        var calls = loader.calls.makeAsyncIterator()

        async let first = cache.load(cwd: "/repo", maximumAge: 5)
        let firstRequest = try #require(await calls.next())
        let initial = Self.status(repositoryName: "initial")
        loader.complete(requestID: firstRequest.id, with: initial)
        #expect(await first == initial)

        clock.value = 104
        #expect(await cache.load(cwd: "/repo", maximumAge: 5) == initial)
        #expect(loader.callCount == 1)

        clock.value = 106
        async let refreshed = cache.load(cwd: "/repo", maximumAge: 5)
        let refreshRequest = try #require(await calls.next())
        let updated = Self.status(repositoryName: "updated")
        loader.complete(requestID: refreshRequest.id, with: updated)
        #expect(await refreshed == updated)
        #expect(loader.callCount == 2)
    }

    @Test func refreshCacheCoalescesConcurrentLoadsForSameGeneration() async throws {
        let loader = ManualGitStatusLoader()
        let cache = PickyGitRepositoryStatusRefreshCache(clock: { 100 }) { cwd in
            await loader.load(cwd: cwd)
        }
        var calls = loader.calls.makeAsyncIterator()

        async let first = cache.load(cwd: "/repo", maximumAge: 0)
        async let second = cache.load(cwd: "/repo", maximumAge: 0)
        let request = try #require(await calls.next())
        var bothCallersJoined = false
        for _ in 0..<1_000 {
            if cache.inFlightWaiterCount(cwd: "/repo") == 2 {
                bothCallersJoined = true
                break
            }
            await Task.yield()
        }
        #expect(bothCallersJoined)
        let value = Self.status(repositoryName: "coalesced")
        loader.complete(requestID: request.id, with: value)

        #expect(await first == value)
        #expect(await second == value)
        #expect(loader.callCount == 1)
    }

    @Test func refreshCacheInvalidationDiscardsOlderInFlightCompletion() async throws {
        let loader = ManualGitStatusLoader()
        let cache = PickyGitRepositoryStatusRefreshCache(clock: { 100 }) { cwd in
            await loader.load(cwd: cwd)
        }
        var calls = loader.calls.makeAsyncIterator()

        async let value = cache.load(cwd: "/repo", maximumAge: 5)
        let staleRequest = try #require(await calls.next())
        cache.invalidate(cwd: "/repo")
        let currentRequest = try #require(await calls.next())

        loader.complete(requestID: staleRequest.id, with: Self.status(repositoryName: "stale"))
        let current = Self.status(repositoryName: "current")
        loader.complete(requestID: currentRequest.id, with: current)

        #expect(await value == current)
        #expect(cache.cached(cwd: "/repo") == current)
        #expect(loader.callCount == 2)
    }

    @Test func refreshCacheTemporarilyCachesNegativeResult() async throws {
        let clock = TestGitStatusClock(now: 100)
        let loader = ManualGitStatusLoader()
        let cache = PickyGitRepositoryStatusRefreshCache(clock: { clock.value }) { cwd in
            await loader.load(cwd: cwd)
        }
        var calls = loader.calls.makeAsyncIterator()

        async let first = cache.load(cwd: "/not-a-repo", maximumAge: 5)
        let request = try #require(await calls.next())
        loader.complete(requestID: request.id, with: nil)
        #expect(await first == nil)

        clock.value = 103
        #expect(await cache.load(cwd: "/not-a-repo", maximumAge: 5) == nil)
        #expect(loader.callCount == 1)
    }

    @Test func parsesDiffAndCommitPositionStats() {
        let diff = PickyGitRepositoryStatus.parseNumstat("2\t1\tSources/App.swift\n-\t-\tAssets/logo.png\n3\t0\tREADME.md\n")
        #expect(diff.insertions == 5)
        #expect(diff.deletions == 1)

        let position = PickyGitRepositoryStatus.parseAheadBehind("4\t2\n")
        #expect(position.ahead == 2)
        #expect(position.behind == 4)
    }

    @Test func backgroundGitProbeDisablesOptionalLocksWithoutDroppingEnvironment() {
        let environment = PickyGitRepositoryStatus.backgroundGitProbeEnvironment(
            base: ["PATH": "/usr/bin", "GIT_OPTIONAL_LOCKS": "1"]
        )
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")

        let process = Process()
        PickyGitRepositoryStatus.configureBackgroundGitProbeProcess(
            process,
            arguments: ["status", "--porcelain"],
            cwd: "/tmp/repo"
        )
        #expect(process.executableURL?.path == "/usr/bin/env")
        #expect(process.arguments == ["git", "-C", "/tmp/repo", "status", "--porcelain"])
        #expect(process.environment?["GIT_OPTIONAL_LOCKS"] == "0")
    }

    @Test func loadReturnsNilOutsideGitRepository() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let status = await PickyGitRepositoryStatus.load(cwd: directory.path)

        #expect(status == nil)
    }

    @Test func loadReadsRepositoryBranchDirtyFlagAndDiffStats() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try runGit(["init", "-b", "main"], cwd: directory)
        try runGit(["config", "user.email", "picky@example.com"], cwd: directory)
        try runGit(["config", "user.name", "Picky Tests"], cwd: directory)
        try runGit(["config", "commit.gpgsign", "false"], cwd: directory)
        try runGit(["remote", "add", "origin", "git@github.com:example/product.git"], cwd: directory)
        let fileURL = directory.appendingPathComponent("notes.txt")
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "notes.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)
        try "one\nthree\nfour\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let status = await PickyGitRepositoryStatus.load(cwd: directory.path)

        #expect(status?.repositoryName == "product")
        #expect(status?.branchName == "main")
        #expect(status?.hasUncommittedChanges == true)
        #expect(status?.repositoryDisplayName == "product")
        #expect(status?.branchDisplayName == "main*")
        #expect(status?.insertions == 2)
        #expect(status?.deletions == 1)
        #expect(status?.aheadCount == 0)
        #expect(status?.behindCount == 0)
        #expect(status?.remoteWebURL?.absoluteString == "https://github.com/example/product")
        #expect(status?.branchWebURL?.absoluteString == "https://github.com/example/product/tree/main")
        #expect(PickyGitRepositoryStatus.cached(cwd: directory.path) == status)
    }

    @Test func extractsRepositoryNameFromRemoteWebURL() {
        #expect(PickyGitRepositoryStatus.remoteRepositoryName(from: URL(string: "https://github.com/example/product")!) == "product")
        #expect(PickyGitRepositoryStatus.remoteRepositoryName(from: URL(string: "https://github.com/example/product.git")!) == "product")
    }

    @Test func buildsBranchWebURLFromRemoteWebURL() {
        let remoteWebURL = URL(string: "https://github.com/example/product")!
        let branchURL = PickyGitRepositoryStatus.makeBranchWebURL(
            remoteWebURL: remoteWebURL,
            branchName: "docs/nicepay-linepay-implementation-plan"
        )

        #expect(branchURL?.absoluteString == "https://github.com/example/product/tree/docs/nicepay-linepay-implementation-plan")
    }

    @Test func loadCountsUntrackedTextFilesAsInsertionsAndSkipsBinaries() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try runGit(["init", "-b", "main"], cwd: directory)
        try runGit(["config", "user.email", "picky@example.com"], cwd: directory)
        try runGit(["config", "user.name", "Picky Tests"], cwd: directory)
        try runGit(["config", "commit.gpgsign", "false"], cwd: directory)
        let seedURL = directory.appendingPathComponent("seed.txt")
        try "seed\n".write(to: seedURL, atomically: true, encoding: .utf8)
        try runGit(["add", "seed.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)

        // 3-line text file with trailing newline.
        try "alpha\nbeta\ngamma\n".write(
            to: directory.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        // 2-line text file WITHOUT trailing newline — git counts the dangling line.
        try "one\ntwo".write(
            to: directory.appendingPathComponent("snippet.txt"),
            atomically: true,
            encoding: .utf8
        )
        // Binary blob — should be skipped.
        try Data([0x00, 0x01, 0x02, 0x00, 0xFF]).write(to: directory.appendingPathComponent("blob.bin"))

        let status = await PickyGitRepositoryStatus.load(cwd: directory.path)

        #expect(status?.insertions == 5) // 3 + 2, blob skipped
        #expect(status?.deletions == 0)
        #expect(status?.hasUncommittedChanges == true)
    }

    @Test func textFileLineCountReturnsNilForBinaryAndCountsLinesWithoutTrailingNewline() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let textWithTrailing = directory.appendingPathComponent("a.txt")
        try "x\ny\nz\n".write(to: textWithTrailing, atomically: true, encoding: .utf8)
        let textWithoutTrailing = directory.appendingPathComponent("b.txt")
        try "x\ny\nz".write(to: textWithoutTrailing, atomically: true, encoding: .utf8)
        let binary = directory.appendingPathComponent("c.bin")
        try Data([0x42, 0x00, 0x42]).write(to: binary)
        let empty = directory.appendingPathComponent("d.txt")
        try Data().write(to: empty)

        #expect(PickyGitRepositoryStatus.textFileLineCount(at: textWithTrailing.path) == 3)
        #expect(PickyGitRepositoryStatus.textFileLineCount(at: textWithoutTrailing.path) == 3)
        #expect(PickyGitRepositoryStatus.textFileLineCount(at: binary.path) == nil)
        #expect(PickyGitRepositoryStatus.textFileLineCount(at: empty.path) == 0)
    }

    @Test func loadKeepsCachedStatusAvailableBetweenRefreshes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try runGit(["init", "-b", "main"], cwd: directory)
        try runGit(["config", "user.email", "picky@example.com"], cwd: directory)
        try runGit(["config", "user.name", "Picky Tests"], cwd: directory)
        try runGit(["config", "commit.gpgsign", "false"], cwd: directory)
        let fileURL = directory.appendingPathComponent("notes.txt")
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "notes.txt"], cwd: directory)
        try runGit(["commit", "-m", "initial"], cwd: directory)

        #expect(PickyGitRepositoryStatus.cached(cwd: directory.path) == nil)
        let cleanStatus = await PickyGitRepositoryStatus.load(cwd: directory.path)
        #expect(PickyGitRepositoryStatus.cached(cwd: directory.path) == cleanStatus)

        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        #expect(PickyGitRepositoryStatus.cached(cwd: directory.path)?.hasUncommittedChanges == false)
        let dirtyStatus = await PickyGitRepositoryStatus.load(cwd: directory.path)
        #expect(dirtyStatus?.hasUncommittedChanges == true)
        #expect(PickyGitRepositoryStatus.cached(cwd: directory.path) == dirtyStatus)
    }

    private static func status(repositoryName: String) -> PickyGitRepositoryStatus {
        PickyGitRepositoryStatus(
            repositoryName: repositoryName,
            branchName: "main",
            hasUncommittedChanges: false,
            insertions: 0,
            deletions: 0,
            aheadCount: 0,
            behindCount: 0,
            remoteWebURL: nil,
            branchWebURL: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-git-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

private final class TestGitStatusClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval

    init(now: TimeInterval) {
        storedValue = now
    }

    var value: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class ManualGitStatusLoader: @unchecked Sendable {
    struct Request: Sendable {
        let id: Int
        let cwd: String?
    }

    let calls: AsyncStream<Request>

    private let lock = NSLock()
    private let callContinuation: AsyncStream<Request>.Continuation
    private var nextRequestID = 0
    private var continuations: [Int: CheckedContinuation<PickyGitRepositoryStatus?, Never>] = [:]
    private var storedCallCount = 0

    init() {
        var continuation: AsyncStream<Request>.Continuation?
        calls = AsyncStream { continuation = $0 }
        callContinuation = continuation!
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    func load(cwd: String?) async -> PickyGitRepositoryStatus? {
        await withCheckedContinuation { continuation in
            lock.lock()
            nextRequestID += 1
            let request = Request(id: nextRequestID, cwd: cwd)
            continuations[request.id] = continuation
            storedCallCount += 1
            lock.unlock()
            callContinuation.yield(request)
        }
    }

    func complete(requestID: Int, with value: PickyGitRepositoryStatus?) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: requestID)
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
