//
//  PickyFullscreenSidebarGroupingTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenSidebarGrouping")
struct PickyFullscreenSidebarGroupingTests {
    @Test func groupsWorktreesByRepositoryDirectoryName() {
        let sessions = [
            session(id: "one", cwd: "/Users/me/.worktrees/product/feature-a", updatedAt: 10),
            session(id: "two", cwd: "/Users/me/.worktrees/product/feature-b", updatedAt: 20)
        ]

        let groups = PickyFullscreenSidebarGrouping.groups(from: sessions)

        #expect(groups.count == 1)
        #expect(groups.first?.label == "product")
        #expect(groups.first?.sessions.map(\.id) == ["one", "two"])
    }

    @Test func groupsNonRepositorySessionsByCwdBasename() {
        let sessions = [
            session(id: "one", cwd: "/Users/me/Documents/picky", updatedAt: 10),
            session(id: "two", cwd: "/Users/me/Documents/product", updatedAt: 20)
        ]

        let groups = PickyFullscreenSidebarGrouping.groups(from: sessions)

        #expect(groups.map(\.label) == ["product", "picky"])
    }

    @Test func emptyInputReturnsNoGroups() {
        #expect(PickyFullscreenSidebarGrouping.groups(from: []).isEmpty)
    }

    @Test func groupLabelUsesBasename() {
        let group = PickyFullscreenSidebarGrouping.groups(from: [
            session(id: "one", cwd: "/Users/me/Documents/creatrip-app", updatedAt: 10)
        ]).first

        #expect(group?.label == "creatrip-app")
    }

    @Test func groupsSortByLatestSessionUpdateWhileKeepingSessionOrder() {
        let sessions = [
            session(id: "old", cwd: "/Users/me/Documents/old", updatedAt: 30),
            session(id: "new-a", cwd: "/Users/me/Documents/new", updatedAt: 10),
            session(id: "new-b", cwd: "/Users/me/Documents/new", updatedAt: 40)
        ]

        let groups = PickyFullscreenSidebarGrouping.groups(from: sessions)

        #expect(groups.map(\.label) == ["new", "old"])
        #expect(groups.first?.sessions.map(\.id) == ["new-a", "new-b"])
    }

    private func session(id: String, cwd: String?, updatedAt: TimeInterval) -> PickySessionListViewModel.SessionCard {
        PickyAgentSession(
            id: id,
            title: "Session \(id)",
            status: .completed,
            cwd: cwd,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + updatedAt),
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: [],
            messages: []
        ).toSessionCard()
    }
}

private extension PickyAgentSession {
    func toSessionCard() -> PickySessionListViewModel.SessionCard {
        PickySessionListViewModel.SessionCard.fromAgentSession(self)
    }
}
