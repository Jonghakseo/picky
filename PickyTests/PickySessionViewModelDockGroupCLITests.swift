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

private final class CLIGroupDockLayoutStore: PickyDockLayoutStoring {
    private var storedLayout: PickyDockLayout
    private(set) var savedLayouts: [PickyDockLayout] = []

    init(layout: PickyDockLayout = .empty) {
        self.storedLayout = layout
    }

    func load() -> PickyDockLayout { storedLayout }

    func save(_ layout: PickyDockLayout) throws {
        storedLayout = layout
        savedLayouts.append(layout)
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
          "protocolVersion": "2026-07-17",
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
