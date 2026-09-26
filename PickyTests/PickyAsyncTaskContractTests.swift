import Combine
import Foundation
import Observation
import Testing
@testable import Picky

@MainActor
struct PickyAsyncTaskContractTests {
    @Test(arguments: ["bash", "subagent"])
    func actualProviderFramesReplayToPersistedShelfComposerAndDock(provider: String) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/async-tasks/runtime-replay/\(provider).json")
        let recording = try JSONDecoder().decode(ProviderReplayRecording.self, from: Data(contentsOf: url))
        let storage = PickyRegistrySessionProjectionStorage()
        let model = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        var checkpointIndex = 0
        for (index, frame) in recording.frames.enumerated() {
            let envelope = try decoder.decode(PickyEventEnvelope.self, from: frame)
            model.apply(.protocolEvent(envelope))
            guard checkpointIndex < recording.checkpoints.count,
                  recording.checkpoints[checkpointIndex].through == index else { continue }
            let checkpoint = recording.checkpoints[checkpointIndex]
            checkpointIndex += 1
            let expected = checkpoint.disk
            let store = storage.registry.sessionStore(sessionID: "session-sdk")
            let metadata = try #require(loaded(store.metaStore.metadataState))
            let detail = try #require(loaded(store.asyncTaskStore.detailState))
            let summary = try #require(metadata.asyncWorkSummary)
            let diskTasks = try decoder.decode([PickyAsyncTask].self, from: expected.asyncTasks)
            let diskTickets = try decoder.decode([PickyCompletionTicket].self, from: expected.completionTickets)
            let diskSummary = try decoder.decode(PickyAsyncWorkSummary.self, from: expected.asyncWorkSummary)
            let diskCycle = try decoder.decode(PickyAgentCycle.self, from: expected.agentCycle)
            #expect(metadata.revision == expected.revision)
            #expect(metadata.status.rawValue == expected.status)
            #expect(detail.tasks == diskTasks)
            #expect(detail.tickets == diskTickets)
            #expect(summary == diskSummary)
            #expect(metadata.agentCycle == diskCycle)
            let roots = PickyAsyncTaskShelfPresentation.roots(in: detail)
            let visible = PickyAsyncTaskShelfPresentation.isVisible(summary: summary, detail: .loaded(detail))
            let dock = try #require(store.dockStore.projection)
            #expect(dock.asyncActiveCount == summary.activeRootCount)
            #expect(dock.asyncRetainsWork == !summary.canReleaseRuntime)
            let composer = PickyConversationComposerProjection(metaStore: store.metaStore,
                conversationStore: store.conversationStore, queueStore: store.queueStore)
            if provider == "bash" {
                if checkpoint.name == "tool-returned-running" || checkpoint.name == "result-pending" {
                    #expect(visible && roots.count == 1)
                    #expect(composer.submitStatus == .completed)
                    if checkpoint.name == "result-pending" {
                        #expect(PickyAsyncTaskShelfPresentation.primaryStateKey(roots[0], tickets: detail.tickets)
                            == "hud.asyncTasks.result.pending")
                    }
                } else {
                    #expect(!visible && roots.isEmpty)
                }
            } else if checkpoint.name == "child-exited-settled" {
                #expect(!visible && roots.isEmpty)
            } else {
                #expect(visible && roots.count == 1)
                #expect(PickyAsyncTaskShelfPresentation.members(of: roots[0], in: detail).count == 2)
                #expect(composer.submitStatus == .completed)
                #expect(!summary.canReleaseRuntime)
            }
        }
        #expect(checkpointIndex == 3)
    }

    @Test func commandDTOsRoundTripSharedFixtures() throws {
        let urls = try fixtureURLs(in: "contracts/extensions/async-tasks-v1/commands")
        #expect(urls.count == 7)
        for url in urls {
            let data = try Data(contentsOf: url)
            let encoded: Data
            if url.lastPathComponent == "result.json" {
                encoded = try JSONEncoder().encode(JSONDecoder().decode(PickyAsyncTaskCommandResult.self, from: data))
            } else {
                encoded = try JSONEncoder().encode(JSONDecoder().decode(PickyAsyncTaskCommand.self, from: data))
            }
            #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == JSONDecoder().decode(JSONValue.self, from: data))
        }
    }

    @Test func snapshotAndTransactionPreserveTasksThroughRegistryAndLegacyRoundTrip() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let snapshot = try decoder.decode(PickySessionProjectionSnapshot.self, from: fixture("session-async-tasks-snapshot.event.json"))
        let transaction = try decoder.decode(PickySessionProjectionTransaction.self, from: fixture("session-async-tasks-transaction.event.json"))
        let storage = PickyRegistrySessionProjectionStorage()
        let card = try #require(storage.applyProjectionSnapshot(snapshot, archived: false))
        let store = storage.registry.sessionStore(sessionID: card.id)
        #expect(loaded(store.asyncTaskStore.detailState)?.tasks.first?.presence == .unknown)
        #expect(card.asyncWorkSummary?.canReleaseRuntime == false)
        #expect(card.asyncTasks?.first?.kind == "future-agent")
        #expect(card.asyncTasks?.first?.details?["future"] == .object(["preserved": .bool(true)]))
        let conversationStore = store.conversationStore
        let updated = try #require(storage.applyProjectionTransaction(transaction, archived: false))
        #expect(store.conversationStore === conversationStore)
        #expect(updated.completionTickets?.first?.state == .pending)
        #expect(updated.asyncWorkSummary?.episode?.id == "cycle-1")
        #expect(updated.asyncWorkSummary?.episode?.finalizedCycleId == updated.agentCycle?.cycleId)
        #expect(updated.asyncWorkSummary?.episode?.settled == false)
        let summary = try #require(storage.sessionSummaryForCLI(id: card.id))
        #expect(summary.asyncTasks == snapshot.projection.asyncTasks)
        #expect(summary.asyncControl == snapshot.projection.asyncControl)
        #expect(summary.asyncWorkSummary?.episode == updated.asyncWorkSummary?.episode)
        #expect(loaded(store.metaStore.metadataState)?.asyncWorkSummary?.episode == updated.asyncWorkSummary?.episode)
        #expect(summary.agentCycle == snapshot.projection.agentCycle)
        let legacy = PickyRegistrySessionProjectionStorage()
        legacy.replaceAllSessions(active: [updated], archived: [])
        #expect(legacy.sessionSummaryForCLI(id: card.id)?.asyncTasks == summary.asyncTasks)
        let encoded = try JSONEncoder.pickyAgentProtocolEncoder().encode(summary)
        #expect(try decoder.decode(PickyAgentSession.self, from: encoded) == summary)
    }

    @Test func v2AsyncMetadataRoutesIdleComposerAndKeepsDockScalarStableAcrossDetailProgress() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        var object = try #require(JSONSerialization.jsonObject(with: fixture("session-async-tasks-snapshot.event.json")) as? [String: Any])
        var projection = try #require(object["projection"] as? [String: Any])
        projection["status"] = "running"
        var cycle = try #require(projection["agentCycle"] as? [String: Any])
        cycle["phase"] = "idle"
        cycle.removeValue(forKey: "outcome")
        projection["agentCycle"] = cycle
        var summary = try #require(projection["asyncWorkSummary"] as? [String: Any])
        summary["activeRootCount"] = 1
        projection["asyncWorkSummary"] = summary
        object["projection"] = projection
        let snapshot = try decoder.decode(PickySessionProjectionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let storage = PickyRegistrySessionProjectionStorage()
        storage.applyProjectionSnapshot(snapshot, archived: false)
        let store = storage.registry.sessionStore(sessionID: snapshot.sessionId)
        #expect(PickyConversationComposerProjection(metaStore: store.metaStore,
            conversationStore: store.conversationStore, queueStore: store.queueStore).submitStatus == .completed)
        #expect(store.dockStore.projection?.asyncActiveCount == 1)
        #expect(store.dockStore.projection?.asyncAttentionCount == 1)
        #expect(store.dockStore.projection?.asyncRetainsWork == true)
        #expect(PickyConversationStoreResolver.card(from: store)?.asyncTasks == nil)
        let stableDock = store.dockStore.projection
        var task = try #require(store.materializedAgentSessionSummary()?.asyncTasks?.first)
        task.progress = "New output"
        store.asyncTaskStore.replaceDetail(.init(tasks: [task], tickets: []))
        #expect(store.dockStore.projection == stableDock)
        #expect(PickyConversationStoreResolver.card(from: store)?.asyncTasks == nil)
        #expect(store.materializedAgentSessionSummary()?.asyncTasks?.first?.progress == "New output")
    }

    @Test func detailOnlyProgressDoesNotPublishConversationCards() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let snapshot = try decoder.decode(PickySessionProjectionSnapshot.self, from: fixture("session-async-tasks-snapshot.event.json"))
        let storage = PickyRegistrySessionProjectionStorage()
        storage.applyProjectionSnapshot(snapshot, archived: false)
        var publications = 0
        let subscription = storage.changes.sink { _ in publications += 1 }
        var object = try #require(JSONSerialization.jsonObject(with: fixture("session-async-tasks-transaction.event.json")) as? [String: Any])
        var mutations = try #require(object["mutations"] as? [[String: Any]])
        mutations.removeAll { $0["type"] as? String != "asyncTaskDetailSet" }
        var detail = try #require(mutations[0]["detail"] as? [String: Any])
        var tasks = try #require(detail["tasks"] as? [[String: Any]])
        tasks[0]["progress"] = "Reading source"
        detail["tasks"] = tasks
        mutations[0]["detail"] = detail
        object["mutations"] = mutations
        let transaction = try decoder.decode(PickySessionProjectionTransaction.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(storage.applyAsyncTaskDetailTransaction(transaction))
        #expect(publications == 0)
        #expect(storage.sessionSummaryForCLI(id: snapshot.sessionId)?.asyncTasks?.first?.progress == "Reading source")
        withExtendedLifetime(subscription) {}
    }

    @Test func omittedDetailIsUnavailableWithoutErasingSafetySummary() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let full = try fixture("session-async-tasks-snapshot.event.json")
        let storage = PickyRegistrySessionProjectionStorage()
        let initial = try decoder.decode(PickySessionProjectionSnapshot.self, from: full)
        storage.applyProjectionSnapshot(initial, archived: false)
        var object = try #require(JSONSerialization.jsonObject(with: full) as? [String: Any])
        object["complete"] = false
        object["omittedFields"] = ["asyncTasks", "completionTickets", "asyncControl"]
        var projection = try #require(object["projection"] as? [String: Any])
        projection.removeValue(forKey: "asyncTasks")
        projection.removeValue(forKey: "completionTickets")
        projection.removeValue(forKey: "asyncControl")
        object["projection"] = projection
        let omitted = try decoder.decode(PickySessionProjectionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        storage.applyProjectionSnapshot(omitted, archived: false)
        let store = storage.registry.sessionStore(sessionID: initial.sessionId)
        #expect(loaded(store.asyncTaskStore.detailState) == nil)
        #expect(loaded(store.metaStore.metadataState)?.asyncWorkSummary?.uncertainExecutionCount == 1)
        #expect(store.materializedAgentSessionSummary()?.asyncTasks == nil)
    }

    @Test func rejectsDuplicateTaskIdentityUnknownExecutionAndMissingRoot() throws {
        let data = try fixture("session-async-tasks-snapshot.event.json")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(object["projection"] as? [String: Any])
        let tasks = try #require(session["asyncTasks"] as? [[String: Any]])
        let tickets = try #require(session["completionTickets"] as? [[String: Any]])
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        #expect(throws: (any Error).self) {
            try decoder.decode(PickyAsyncTaskDetail.self, from: JSONSerialization.data(withJSONObject: ["tasks": tasks + tasks, "tickets": tickets]))
        }
        for change in [["presence": "probablyDone"], ["rootTaskId": "missing"], ["title": String(repeating: "x", count: 501)]] {
            var invalid = try #require(tasks.first)
            invalid.merge(change) { _, new in new }
            #expect(throws: (any Error).self) {
                try decoder.decode(PickyAsyncTaskDetail.self, from: JSONSerialization.data(withJSONObject: ["tasks": [invalid], "tickets": tickets]))
            }
        }
    }

    @Test func episodeRejectsMissingFinalizationAndInvalidIdentity() throws {
        let decoder = JSONDecoder()
        for json in [
            #"{"id":"cycle","settled":true}"#,
            #"{"id":"","settled":false}"#,
            #"{"id":"cycle","settled":false,"finalizedCycleId":""}"#,
            #"{"id":"cycle","settled":true,"finalizedCycleId":"cycle","outcome":"unknown"}"#
        ] {
            #expect(throws: (any Error).self) {
                try decoder.decode(PickyAsyncWorkSummary.Episode.self, from: Data(json.utf8))
            }
        }
        let data = Data(#"{"id":"first","settled":true,"finalizedCycleId":"last","outcome":"completed"}"#.utf8)
        let value = try decoder.decode(PickyAsyncWorkSummary.Episode.self, from: data)
        #expect(try decoder.decode(PickyAsyncWorkSummary.Episode.self, from: JSONEncoder().encode(value)) == value)
    }

    private func loaded<Value>(_ state: PickyProjectionSectionState<Value>) -> Value? {
        if case .loaded(let value) = state { return value }
        return nil
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(fixtureURLs(in: "contracts/protocol").first { $0.lastPathComponent == name })
        return try Data(contentsOf: url)
    }
}

private struct ProviderReplayRecording: Decodable {
    struct Checkpoint: Decodable {
        struct Disk: Decodable {
            let revision: Int
            let status: String
            let asyncTasks: Data
            let completionTickets: Data
            let asyncWorkSummary: Data
            let agentCycle: Data

            enum CodingKeys: String, CodingKey {
                case revision, status, asyncTasks, completionTickets, asyncWorkSummary, agentCycle
            }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                revision = try container.decode(Int.self, forKey: .revision)
                status = try container.decode(String.self, forKey: .status)
                func bytes(_ key: CodingKeys) throws -> Data {
                    let json = try container.decode(JSONValue.self, forKey: key)
                    return try JSONEncoder().encode(json)
                }
                asyncTasks = try bytes(.asyncTasks)
                completionTickets = try bytes(.completionTickets)
                asyncWorkSummary = try bytes(.asyncWorkSummary)
                agentCycle = try bytes(.agentCycle)
            }
        }
        let name: String
        let through: Int
        let disk: Disk
    }
    let frames: [Data]
    let checkpoints: [Checkpoint]

    enum CodingKeys: String, CodingKey { case frames, checkpoints }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frames = try container.decode([JSONValue].self, forKey: .frames).map { try JSONEncoder().encode($0) }
        checkpoints = try container.decode([Checkpoint].self, forKey: .checkpoints)
    }
}
