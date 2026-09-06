import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyMainAgentConversationStoreTests {
    private func message(_ text: String) -> PickyMainAgentMessage {
        PickyMainAgentMessage(role: .assistant, text: text, createdAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test func transcriptKeepsOnlyTheNewestRetainedMessages() {
        let store = PickyMainAgentConversationStore()
        let retention = PickyMainAgentConversationStore.messageRetention

        store.replaceMessages((0..<(retention + 5)).map { message("m\($0)") })
        #expect(store.messages.count == retention)
        #expect(store.messages.first?.text == "m5")

        store.appendMessage(message("tail"))
        #expect(store.messages.count == retention)
        #expect(store.messages.last?.text == "tail")
        #expect(store.messages.first?.text == "m6")

        store.clearMessages()
        #expect(store.messages.isEmpty)
    }

    @Test func modelOptionsLoadingFlagFollowsSnapshotAndFailure() {
        let store = PickyMainAgentConversationStore()
        store.beginLoadingModelOptions()
        #expect(store.isLoadingModelOptions)

        store.failLoadingModelOptions()
        #expect(!store.isLoadingModelOptions)

        store.beginLoadingModelOptions()
        store.applyModelOptions([])
        #expect(!store.isLoadingModelOptions)
    }
}
