//
//  PickyFullscreenBranchDiffProviderTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@Suite("PickyFullscreenBranchDiffProvider")
struct PickyFullscreenBranchDiffProviderTests {
    @MainActor
    @Test func sumsMergeBaseAndWorkingTreeChanges() async {
        let runner = StubGitRunner(outputs: [
            "rev-parse --show-toplevel": "/repo\n",
            "rev-parse HEAD": "head-sha\n",
            "status --porcelain=v1": " M Sources/App.swift\n",
            "symbolic-ref refs/remotes/origin/HEAD": "refs/remotes/origin/main\n",
            "merge-base refs/remotes/origin/main HEAD": "base-sha\n",
            "diff --numstat base-sha..HEAD": "10\t2\tSources/App.swift\n3\t0\tSources/New.swift\n",
            "diff --name-status base-sha..HEAD": "M\tSources/App.swift\nA\tSources/New.swift\n",
            "diff --numstat": "5\t1\tSources/App.swift\n",
            "diff --name-status": "M\tSources/App.swift\n"
        ])
        let provider = PickyFullscreenBranchDiffProvider(cwd: "/repo", gitRunner: runner.run)

        let summary = await provider.fetchSummary()

        #expect(summary?.baseRef == "refs/remotes/origin/main")
        #expect(summary?.mergeBaseRef == "base-sha")
        #expect(summary?.totalInsertions == 18)
        #expect(summary?.totalDeletions == 3)
        #expect(summary?.files.first(where: { $0.path == "Sources/App.swift" })?.insertions == 15)
        #expect(summary?.files.first(where: { $0.path == "Sources/App.swift" })?.deletions == 3)
        #expect(summary?.files.first(where: { $0.path == "Sources/App.swift" })?.hasCommittedChanges == true)
        #expect(summary?.files.first(where: { $0.path == "Sources/App.swift" })?.hasWorkingTreeChanges == true)
    }

    @MainActor
    @Test func fallsBackToOriginMainWhenOriginHeadIsMissing() async {
        let runner = StubGitRunner(outputs: [
            "rev-parse --show-toplevel": "/repo\n",
            "rev-parse HEAD": "head-sha\n",
            "status --porcelain=v1": "",
            "rev-parse --verify origin/main": "main-sha\n",
            "merge-base origin/main HEAD": "base-sha\n",
            "diff --numstat base-sha..HEAD": "1\t0\tREADME.md\n",
            "diff --name-status base-sha..HEAD": "M\tREADME.md\n",
            "diff --numstat": "",
            "diff --name-status": ""
        ])
        let provider = PickyFullscreenBranchDiffProvider(cwd: "/repo", gitRunner: runner.run)

        let summary = await provider.fetchSummary()

        #expect(summary?.baseRef == "origin/main")
        #expect(summary?.files.map(\.path) == ["README.md"])
    }

    @MainActor
    @Test func usesWorkingTreeOnlyWhenNoBaseExists() async {
        let runner = StubGitRunner(outputs: [
            "rev-parse --show-toplevel": "/repo\n",
            "rev-parse HEAD": "head-sha\n",
            "status --porcelain=v1": " M Local.swift\n",
            "diff --numstat": "7\t4\tLocal.swift\n",
            "diff --name-status": "M\tLocal.swift\n"
        ])
        let provider = PickyFullscreenBranchDiffProvider(cwd: "/repo", gitRunner: runner.run)

        let summary = await provider.fetchSummary()

        #expect(summary?.baseRef == nil)
        #expect(summary?.mergeBaseRef == nil)
        #expect(summary?.totalInsertions == 7)
        #expect(summary?.totalDeletions == 4)
        #expect(summary?.files.first?.hasCommittedChanges == false)
        #expect(summary?.files.first?.hasWorkingTreeChanges == true)
    }

    @MainActor
    @Test func cachesSummaryByProviderInstance() async {
        let runner = StubGitRunner(outputs: [
            "rev-parse --show-toplevel": "/repo\n",
            "rev-parse HEAD": "head-sha\n",
            "status --porcelain=v1": "",
            "symbolic-ref refs/remotes/origin/HEAD": "refs/remotes/origin/main\n",
            "merge-base refs/remotes/origin/main HEAD": "base-sha\n",
            "diff --numstat base-sha..HEAD": "1\t0\tREADME.md\n",
            "diff --name-status base-sha..HEAD": "M\tREADME.md\n",
            "diff --numstat": "",
            "diff --name-status": ""
        ])
        let provider = PickyFullscreenBranchDiffProvider(cwd: "/repo", gitRunner: runner.run)

        _ = await provider.fetchSummary()
        _ = await provider.fetchSummary()

        #expect(await runner.count(for: "rev-parse HEAD") == 1)
        #expect(await runner.count(for: "diff --numstat base-sha..HEAD") == 1)
    }

    @MainActor
    @Test func fetchDiffCombinesCommittedAndWorkingTreeSections() async {
        let runner = StubGitRunner(outputs: [
            "rev-parse --show-toplevel": "/repo\n",
            "rev-parse HEAD": "head-sha\n",
            "status --porcelain=v1": " M Sources/App.swift\n",
            "symbolic-ref refs/remotes/origin/HEAD": "refs/remotes/origin/main\n",
            "merge-base refs/remotes/origin/main HEAD": "base-sha\n",
            "diff --numstat base-sha..HEAD": "1\t0\tSources/App.swift\n",
            "diff --name-status base-sha..HEAD": "M\tSources/App.swift\n",
            "diff --numstat": "2\t1\tSources/App.swift\n",
            "diff --name-status": "M\tSources/App.swift\n",
            "diff base-sha..HEAD -- Sources/App.swift": "diff --git a/Sources/App.swift b/Sources/App.swift\n+branch\n",
            "diff -- Sources/App.swift": "diff --git a/Sources/App.swift b/Sources/App.swift\n+local\n"
        ])
        let provider = PickyFullscreenBranchDiffProvider(cwd: "/repo", gitRunner: runner.run)

        let diff = await provider.fetchDiff(path: "Sources/App.swift")

        #expect(diff?.contains("# Branch changes") == true)
        #expect(diff?.contains("+branch") == true)
        #expect(diff?.contains("# Working tree changes") == true)
        #expect(diff?.contains("+local") == true)
    }
}

private actor StubGitRunner {
    private let outputs: [String: String]
    private var calls: [String: Int] = [:]

    init(outputs: [String: String]) {
        self.outputs = outputs
    }

    func run(arguments: [String], cwd: String) async -> String? {
        let key = arguments.joined(separator: " ")
        calls[key, default: 0] += 1
        return outputs[key]
    }

    func count(for key: String) -> Int {
        calls[key, default: 0]
    }
}
