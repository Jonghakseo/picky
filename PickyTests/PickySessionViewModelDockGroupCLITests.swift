//
//  PickySessionViewModelDockGroupCLITests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class CLIGroupFakePickyAgentClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "session-1", message: "sent")
    }

    func send(_ command: PickyCommandEnvelope) async throws {}
    func disconnect() { continuation.yield(.disconnected) }
}

private final class CLIGroupArchiveStore: PickySessionArchiveStoring {
    var archivedSessionIDs = Set<String>()
    var manuallyArchivedSessionIDs = Set<String>()
}

private final class CLIGroupDockLayoutStore: PickyDockLayoutStoring {
    enum SaveError: Error { case failed }

    private var storedLayout: PickyDockLayout
    private(set) var savedLayouts: [PickyDockLayout] = []
    var errorToThrow: Error?

    init(layout: PickyDockLayout = .empty) {
        self.storedLayout = layout
    }

    func load() -> PickyDockLayout { storedLayout }

    func enqueueSave(
        _ layout: PickyDockLayout,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        if let errorToThrow {
            completion(.failure(errorToThrow))
            return
        }
        storedLayout = layout
        savedLayouts.append(layout)
        completion(.success(()))
    }
}

private extension PickyDockLayout {
    var cliGroupTestEntryDescriptions: [String] {
        entries.map { entry in
            switch entry {
            case .session(let id): "session:\(id)"
            case .group(let group): "group:\(group.id)[\(group.memberSessionIDs.joined(separator: ","))]"
            }
        }
    }
}

struct PickySessionViewModelDockGroupCLITests {
    private static func decodeEnvelope(_ json: String) throws -> PickyEventEnvelope {
        try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(json.utf8))
    }

    private static func sessionSnapshot(_ ids: [String]) -> PickyEventEnvelope {
        let sessions = ids.enumerated().map { index, id in
            PickyAgentSession(
                id: id,
                title: id.uppercased(),
                status: .running,
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(1_800_000_100 + index)),
                logs: [],
                tools: [],
                artifacts: [],
                changedFiles: []
            )
        }
        return PickyEventEnvelope(
            id: "snapshot-group-management",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: .sessionSnapshot(PickySessionSnapshot(sessions: sessions))
        )
    }

    @MainActor @Test func dockLayoutStoreSeedsInitialPublishedLayout() {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(
                id: "g",
                name: "G",
                color: .teal,
                memberSessionIDs: ["b"]
            ))
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )

        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["session:a", "group:g[b]"])
        #expect(dockLayoutStore.savedLayouts.isEmpty)
    }

    @MainActor @Test func moveSessionInDockPublishesControllerLayoutAndPersists() {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(
                id: "g",
                name: "G",
                color: .teal,
                memberSessionIDs: ["b"]
            )),
            .session(id: "c")
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )

        viewModel.moveSessionInDock(sessionID: "a", to: .group(id: "g", memberIndex: 1))

        let expectedLayout = ["group:g[b,a]", "session:c"]
        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == expectedLayout)
        #expect(dockLayoutStore.savedLayouts.map(\.cliGroupTestEntryDescriptions) == [expectedLayout])
    }

    @MainActor @Test func createsMissingGroupAfterReconcile() throws {
        let dockLayoutStore = CLIGroupDockLayoutStore()
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )

        viewModel.assignSessionToDockGroup(sessionID: "a", groupName: "Research")
        viewModel.apply(.protocolEvent(try Self.decodeEnvelope("""
        {
          "id": "snapshot-cli-group",
          "protocolVersion": "2026-07-23",
          "timestamp": "2026-05-01T00:00:30.000Z",
          "type": "sessionSnapshot",
          "sessions": [
            {
              "id": "a",
              "title": "A",
              "status": "running",
              "cwd": "/tmp/ws",
              "createdAt": "2026-05-01T00:00:00.000Z",
              "updatedAt": "2026-05-01T00:00:00.000Z",
              "lastSummary": "a",
              "logs": [],
              "tools": [],
              "artifacts": [],
              "changedFiles": []
            }
          ]
        }
        """)))

        let group = viewModel.dockLayout.groups.first
        #expect(viewModel.dockLayout.entries.count == 1)
        #expect(group?.name == "Research")
        #expect(group?.memberSessionIDs == ["a"])
    }

    @MainActor @Test func assignsPendingSessionToExactGroupIDAfterReconcile() throws {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "g1", name: "Research", color: .teal, memberSessionIDs: [])),
            .group(PickyDockGroup(id: "g2", name: "Research", color: .amber, memberSessionIDs: []))
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )

        viewModel.assignSessionToDockGroup(sessionID: "new-pickle", groupID: "g2")
        viewModel.apply(.protocolEvent(try Self.decodeEnvelope("""
        {
          "id": "snapshot-created-pickle",
          "protocolVersion": "2026-07-23",
          "timestamp": "2026-05-01T00:00:30.000Z",
          "type": "sessionSnapshot",
          "sessions": [
            {
              "id": "new-pickle",
              "title": "New Pickle",
              "status": "running",
              "cwd": "/tmp/ws",
              "createdAt": "2026-05-01T00:00:00.000Z",
              "updatedAt": "2026-05-01T00:00:00.000Z",
              "lastSummary": "",
              "logs": [],
              "tools": [],
              "artifacts": [],
              "changedFiles": []
            }
          ]
        }
        """)))

        #expect(viewModel.dockLayout.group(withID: "g1")?.memberSessionIDs == [])
        #expect(viewModel.dockLayout.group(withID: "g2")?.memberSessionIDs == ["new-pickle"])
        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["group:g1[]", "group:g2[new-pickle]"])
    }

    @MainActor @Test func mainAgentCreatesGroupWithKnownMembersAndPersists() async throws {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b")
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )
        viewModel.apply(.protocolEvent(Self.sessionSnapshot(["b", "a"])))

        let groups = try await viewModel.manageDockGroups(PickyDockGroupManagementRequest(
            action: .create,
            groupId: nil,
            name: "  Research  ",
            sessionIds: ["b", "a"]
        ))

        let group = try #require(groups.first)
        #expect(group.name == "Research")
        #expect(group.memberSessionIds == ["b", "a"])
        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["group:\(group.id)[b,a]"])
        #expect(dockLayoutStore.savedLayouts.count == 1)
    }

    @MainActor @Test func mainAgentAddsAndRemovesMembersThroughPersistedDockLayout() async throws {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "Research", color: .teal, memberSessionIDs: ["b"])),
            .session(id: "c")
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )
        viewModel.apply(.protocolEvent(Self.sessionSnapshot(["c", "b", "a"])))

        _ = try await viewModel.manageDockGroups(PickyDockGroupManagementRequest(
            action: .addMembers,
            groupId: "g",
            name: nil,
            sessionIds: ["a", "c"]
        ))
        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["group:g[b,a,c]"])

        _ = try await viewModel.manageDockGroups(PickyDockGroupManagementRequest(
            action: .removeMembers,
            groupId: "g",
            name: nil,
            sessionIds: ["a", "b"]
        ))
        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["group:g[c]", "session:a", "session:b"])
        #expect(dockLayoutStore.savedLayouts.map(\.cliGroupTestEntryDescriptions) == [
            ["group:g[b,a,c]"],
            ["group:g[c]", "session:a", "session:b"]
        ])
    }

    @MainActor @Test func mainAgentRemovesGroupWhileKeepingMembersActive() async throws {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "Research", color: .teal, memberSessionIDs: ["b", "c"]))
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )
        viewModel.apply(.protocolEvent(Self.sessionSnapshot(["c", "b", "a"])))

        _ = try await viewModel.manageDockGroups(PickyDockGroupManagementRequest(
            action: .removeGroup,
            groupId: "g",
            name: nil,
            sessionIds: []
        ))

        #expect(viewModel.sessions.map(\.id) == ["a", "b", "c"])
        #expect(viewModel.archivedSessions.isEmpty)
        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["session:a", "session:b", "session:c"])
        #expect(dockLayoutStore.savedLayouts.map(\.cliGroupTestEntryDescriptions) == [["session:a", "session:b", "session:c"]])
    }

    @MainActor @Test func mainAgentDeletesGroupByArchivingMembers() async throws {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "Research", color: .teal, memberSessionIDs: ["b", "c"]))
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: CLIGroupArchiveStore(),
            dockLayoutStore: dockLayoutStore,
            archiveCommitDelayNanoseconds: 60_000_000_000
        )
        viewModel.apply(.protocolEvent(Self.sessionSnapshot(["c", "b", "a"])))

        _ = try await viewModel.manageDockGroups(PickyDockGroupManagementRequest(
            action: .archiveGroup,
            groupId: "g",
            name: nil,
            sessionIds: []
        ))

        #expect(viewModel.sessions.map(\.id) == ["a"])
        #expect(Set(viewModel.archivedSessions.map(\.id)) == Set(["b", "c"]))
        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["session:a"])
        #expect(dockLayoutStore.savedLayouts.map(\.cliGroupTestEntryDescriptions) == [["session:a"]])
    }

    @MainActor @Test func groupArchiveSaveFailureLeavesMembersActiveAndGrouped() async {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "Research", color: .teal, memberSessionIDs: ["b", "c"]))
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: CLIGroupArchiveStore(),
            dockLayoutStore: dockLayoutStore,
            archiveCommitDelayNanoseconds: 60_000_000_000
        )
        viewModel.apply(.protocolEvent(Self.sessionSnapshot(["c", "b", "a"])))
        dockLayoutStore.errorToThrow = CLIGroupDockLayoutStore.SaveError.failed

        await #expect(throws: CLIGroupDockLayoutStore.SaveError.self) {
            try await viewModel.manageDockGroups(PickyDockGroupManagementRequest(
                action: .archiveGroup,
                groupId: "g",
                name: nil,
                sessionIds: []
            ))
        }

        #expect(viewModel.archivedSessions.isEmpty)
        #expect(Set(viewModel.sessions.map(\.id)) == Set(["a", "b", "c"]))
        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["session:a", "group:g[b,c]"])
    }

    @MainActor @Test func mainAgentRejectsUnknownSessionsBeforeMutatingLayout() async {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "Research", color: .teal, memberSessionIDs: ["b"]))
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )
        viewModel.apply(.protocolEvent(Self.sessionSnapshot(["b", "a"])))

        await #expect(throws: PickyDockGroupManagementError.sessionNotFound("missing")) {
            try await viewModel.manageDockGroups(PickyDockGroupManagementRequest(
                action: .addMembers,
                groupId: "g",
                name: nil,
                sessionIds: ["a", "missing"]
            ))
        }
        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["session:a", "group:g[b]"])
        #expect(dockLayoutStore.savedLayouts.isEmpty)
    }

    @MainActor @Test func usesFirstCaseInsensitiveNameMatch() {
        let dockLayoutStore = CLIGroupDockLayoutStore(layout: PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "g1", name: "Research", color: .teal, memberSessionIDs: ["b"])),
            .group(PickyDockGroup(id: "g2", name: "research", color: .amber, memberSessionIDs: [])),
            .session(id: "a")
        ]))
        let viewModel = PickySessionListViewModel(
            client: CLIGroupFakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )

        viewModel.assignSessionToDockGroup(sessionID: "a", groupName: "research")

        #expect(viewModel.dockLayout.cliGroupTestEntryDescriptions == ["group:g1[b,a]", "group:g2[]"])
    }
}
