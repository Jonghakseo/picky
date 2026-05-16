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

    @Test func cachedEntryIsStaleAfterTtl() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = PickyGitHubPullRequestStatus.CachedEntry(status: nil, fetchedAt: now.addingTimeInterval(-60))
        let stale = PickyGitHubPullRequestStatus.CachedEntry(status: nil, fetchedAt: now.addingTimeInterval(-301))

        #expect(fresh.isStale(now: now) == false)
        #expect(stale.isStale(now: now) == true)
    }
}
