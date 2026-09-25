import Combine
import Foundation
import Observation
import Testing
@testable import Picky

@MainActor
struct PickyAsyncTaskContractTests {
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
