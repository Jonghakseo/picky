//
//  PickyGitHubPullRequestStatusTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyGitHubPullRequestStatusTests {
    @Test func mapsOpenStateAndDraftFlag() {
        #expect(PickyGitHubPullRequestStatus.mapState(rawState: "OPEN", isDraft: false) == .open)
        #expect(PickyGitHubPullRequestStatus.mapState(rawState: "open", isDraft: false) == .open)
        #expect(PickyGitHubPullRequestStatus.mapState(rawState: "OPEN", isDraft: true) == .draft)
    }

    @Test func mapsTerminalStates() {
        #expect(PickyGitHubPullRequestStatus.mapState(rawState: "MERGED", isDraft: false) == .merged)
        #expect(PickyGitHubPullRequestStatus.mapState(rawState: "MERGED", isDraft: true) == .merged)
        #expect(PickyGitHubPullRequestStatus.mapState(rawState: "CLOSED", isDraft: false) == .closed)
    }

    @Test func parsesGhPullRequestPayload() throws {
        let json = """
        {
          "number": 1234,
          "title": "Fix HUD link badges",
          "url": "https://github.com/example/product/pull/1234",
          "state": "OPEN",
          "isDraft": true
        }
        """
        let status = try #require(PickyGitHubPullRequestStatus.parse(json: json))
        #expect(status.number == 1234)
        #expect(status.title == "Fix HUD link badges")
        #expect(status.url.absoluteString == "https://github.com/example/product/pull/1234")
        #expect(status.state == .draft)
    }

    @Test func parseReturnsNilOnInvalidJson() {
        #expect(PickyGitHubPullRequestStatus.parse(json: "") == nil)
        #expect(PickyGitHubPullRequestStatus.parse(json: "{\"number\":1}") == nil)
    }

    @Test func buildsSingleBranchScopedListQuery() {
        let arguments = PickyGitHubPullRequestStatus.listArguments(
            repositoryURL: URL(string: "https://github.com/acme/product"),
            branch: "feature/partner-sheet-sync"
        )

        #expect(arguments == [
            "pr", "list",
            "--repo", "acme/product",
            "--state", "all",
            "--head", "feature/partner-sheet-sync",
            "--limit", "20",
            "--json", "number,title,url,state,isDraft,headRefName,headRepositoryOwner",
        ])
    }

    @Test func selectsMergedPullRequestForExactRepositoryAndBranch() throws {
        let json = """
        [
          {
            "number": 1003,
            "title": "Related sheet work",
            "url": "https://github.com/acme/product/pull/1003",
            "state": "MERGED",
            "isDraft": false,
            "headRefName": "feature/reservation-sheet-sync",
            "headRepositoryOwner": { "login": "acme" }
          },
          {
            "number": 1004,
            "title": "Add partner sheets",
            "url": "https://github.com/acme/product/pull/1004",
            "state": "MERGED",
            "isDraft": false,
            "headRefName": "feature/partner-sheet-sync",
            "headRepositoryOwner": { "login": "acme" }
          }
        ]
        """
        let candidates = try #require(PickyGitHubPullRequestStatus.parseCandidates(json: json))
        let repository = try #require(PickyGitHubPullRequestStatus.RepositoryIdentity(
            url: URL(string: "https://github.com/acme/product")
        ))

        let selected = PickyGitHubPullRequestStatus.selectCandidate(
            candidates,
            repository: repository,
            branch: "feature/partner-sheet-sync",
            artifactURLs: [
                URL(string: "https://github.com/acme/product/pull/1003")!,
                URL(string: "https://github.com/acme/product/pull/1004")!,
            ]
        )

        #expect(selected?.number == 1004)
        #expect(selected?.state == .merged)
    }

    @Test func artifactURLDisambiguatesReusedBranchWithoutExtraLookup() throws {
        let json = """
        [
          {
            "number": 41,
            "title": "Earlier attempt",
            "url": "https://github.com/acme/product/pull/41",
            "state": "MERGED",
            "isDraft": false,
            "headRefName": "fix/reused-branch",
            "headRepositoryOwner": { "login": "acme" }
          },
          {
            "number": 42,
            "title": "Current attempt",
            "url": "https://github.com/acme/product/pull/42",
            "state": "MERGED",
            "isDraft": false,
            "headRefName": "fix/reused-branch",
            "headRepositoryOwner": { "login": "acme" }
          }
        ]
        """
        let candidates = try #require(PickyGitHubPullRequestStatus.parseCandidates(json: json))
        let repository = try #require(PickyGitHubPullRequestStatus.RepositoryIdentity(
            url: URL(string: "https://github.com/acme/product")
        ))

        let selected = PickyGitHubPullRequestStatus.selectCandidate(
            candidates,
            repository: repository,
            branch: "fix/reused-branch",
            artifactURLs: [URL(string: "https://github.com/acme/product/pull/42?tab=files#diff")!]
        )

        #expect(selected?.number == 42)
    }

    @Test func ambiguousReusedBranchWithoutMatchingArtifactReturnsNil() throws {
        let json = """
        [
          {
            "number": 41,
            "title": "Earlier attempt",
            "url": "https://github.com/acme/product/pull/41",
            "state": "MERGED",
            "isDraft": false,
            "headRefName": "fix/reused-branch",
            "headRepositoryOwner": { "login": "acme" }
          },
          {
            "number": 42,
            "title": "Current attempt",
            "url": "https://github.com/acme/product/pull/42",
            "state": "MERGED",
            "isDraft": false,
            "headRefName": "fix/reused-branch",
            "headRepositoryOwner": { "login": "acme" }
          }
        ]
        """
        let candidates = try #require(PickyGitHubPullRequestStatus.parseCandidates(json: json))
        let repository = try #require(PickyGitHubPullRequestStatus.RepositoryIdentity(
            url: URL(string: "https://github.com/acme/product")
        ))

        let selected = PickyGitHubPullRequestStatus.selectCandidate(
            candidates,
            repository: repository,
            branch: "fix/reused-branch",
            artifactURLs: [URL(string: "https://github.com/acme/product/pull/99")!]
        )

        #expect(selected == nil)
    }

    @Test func cacheKeyIncludesRepositoryIdentity() {
        let first = PickyGitHubPullRequestStatus.cacheKey(
            cwd: "/tmp/worktree",
            repositoryURL: URL(string: "https://github.com/acme/product"),
            branch: "fix/shared-name"
        )
        let second = PickyGitHubPullRequestStatus.cacheKey(
            cwd: "/tmp/worktree",
            repositoryURL: URL(string: "https://github.com/other/product"),
            branch: "fix/shared-name"
        )

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
    }

    @Test func cachedEntryIsStaleAfterTtl() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = PickyGitHubPullRequestStatus.CachedEntry(status: nil, fetchedAt: now.addingTimeInterval(-60))
        let stale = PickyGitHubPullRequestStatus.CachedEntry(status: nil, fetchedAt: now.addingTimeInterval(-301))

        #expect(fresh.isStale(now: now) == false)
        #expect(stale.isStale(now: now) == true)
    }
}
