import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyConversationBackgroundWorkVisibilityTests {
    @Test func onlyKnownBackgroundToolMessagesAndLifecycleNoticesAreHidden() {
        for type in ["bash-async-completion", "subagent-tool"] {
            #expect(PickyConversationBubbleKind(message: message(type, customType: type)) == .hiddenActivity)
        }
        for text in ["Started subagent #1: searcher", "Resumed subagent #12: worker",
                     "subagent tool run #1 (searcher) completed", "subagent tool run #2 (worker) failed",
                     "subagent tool run #2 aborted: Cancelled", "subagent batch batch-1 finished with errors"] {
            #expect(PickyConversationBubbleKind(message: message(text, notifyType: .info)) == .hiddenActivity)
        }
        for text in ["Extension ready", "Use subagent to investigate", "Started subagent service",
                     "subagent tool run has no ID", "Please inspect bash_async output"] {
            #expect(PickyConversationBubbleKind(message: message(text, notifyType: .info)) == .notify)
        }
        // A tagged third-party extension is authoritative even if its text quotes a tool notice.
        #expect(PickyConversationBubbleKind(message: message("Started subagent #1: searcher",
            customType: "other-extension", notifyType: .info)) == .notify)
        for type in ["web-search-content-ready", "subagent-command", "subagent-tool-extra"] {
            guard case .extensionCustomMessage = PickyConversationBubbleKind(message: message("Result", customType: type)) else {
                Issue.record("Unrelated extension/command must remain visible: \(type)")
                continue
            }
        }
        for kind in [PickySessionMessageKind.userText, .agentText] {
            #expect(PickyConversationBackgroundWorkVisibility.isVisible(message(
                "subagent tool run #1 (searcher) completed", kind: kind, customType: "subagent-tool")))
        }
    }

    @Test func v2JournalRetainsBackgroundRecordsWhileTheRenderedConversationOmitsOnlyDuplicates() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let model = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        let store = storage.registry.sessionStore(sessionID: "session")
        var invocation = message("Delegated", id: "invocation", kind: .subagentInvocation)
        invocation.subagentInvocation = .init(invocationId: "tool-1", action: .run,
            planned: [.init(agent: "searcher", task: "Inspect project")])
        let records = [
            message("Run both tools", id: "user", kind: .userText),
            invocation,
            message("Started subagent #1: searcher", id: "start", notifyType: .info),
            message("[bash_async job-1] completed", id: "bash", customType: "bash-async-completion"),
            message("subagent tool run #1 (searcher) completed", id: "done", notifyType: .info),
            message("[subagent:searcher#1] completed", id: "subagent", customType: "subagent-tool"),
            message("Web content ready", id: "other-custom", customType: "web-search-content-ready"),
            message("Other extension is ready", id: "other-notify", notifyType: .info),
            message("bash_async and subagent both finished; here are the results", id: "answer", kind: .agentText),
        ]
        var session = PickyProjectionReplayFixtures.bootstrapSession(id: "session", index: 0,
            status: .running, archived: false, messages: records, messageJournalAvailable: true)
        session.asyncTasks = [PickyAsyncTaskShelfFixtures.task("active-work")]
        session.completionTickets = []
        session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary()
        for revision in [1, 2] {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let projection = try JSONSerialization.jsonObject(with: encoder.encode(session))
            let data = try JSONSerialization.data(withJSONObject: ["sessionId": session.id, "epoch": "test-epoch",
                "revision": revision, "complete": true, "omittedFields": [], "projection": projection])
            let snapshot = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: data)
            #expect(storage.applyProjectionSnapshot(snapshot, archived: false) != nil)
            let list = PickyConversationListView(session: try #require(PickyConversationStoreResolver.card(from: store)),
                viewModel: model, conversationStore: store.conversationStore)
            #expect(list.visibleMessages.map(\.id) == ["user", "other-custom", "other-notify", "answer"])
            #expect(list.renderSnapshot.subagentInvocationBubbleCount == 0)
            #expect(list.renderSnapshot.extensionCustomMessageBubbleCount == 1)
            #expect(list.renderSnapshot.notifyBubbleCount == 1)
            #expect(list.hiddenHistoryCount == 0, "Suppressed status rows must not create a more-history affordance")
            #expect(store.conversationStore.orderedMessageIDs == records.map(\.id), "The journal is not deleted or rewritten")
            guard case .loaded(let detail) = store.asyncTaskStore.detailState else {
                Issue.record("Background work must still reach the footer store")
                return
            }
            #expect(detail.tasks.map(\.taskId) == ["active-work"])
        }
    }

    private func message(_ text: String, id: String = "message", kind: PickySessionMessageKind = .system,
                         customType: String? = nil, notifyType: PickyExtensionNotifyType? = nil) -> PickySessionMessage {
        var message = PickySessionMessage(id: id, kind: kind, createdAt: Date(timeIntervalSince1970: 1),
            originatedBy: .piExtension, text: text, question: nil, cancelledAt: nil,
            activitySnapshot: nil, errorContext: nil, errorMessage: nil, customType: customType)
        message.notifyType = notifyType
        return message
    }
}
