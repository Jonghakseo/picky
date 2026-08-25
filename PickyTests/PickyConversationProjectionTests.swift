//
//  PickyConversationProjectionTests.swift
//  PickyTests
//

import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyConversationProjectionTests {
    @Test func cardRetainsTheRegistrySessionStoreIdentity() {
        let registry = PickySessionRegistry()
        let store = registry.sessionStore(sessionID: "session-a")
        let card = PickyConversationCardView(
            viewModel: PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: PickyRegistrySessionProjectionStorage(registry: registry)),
            sessionStore: store
        )

        #expect(card.sessionStore === store)
    }

    @Test func journalPresentationDistinguishesUnavailableFromAnEmptyLoadedJournal() {
        let store = PickyConversationStore()

        #expect(PickyConversationJournalPresentation(state: store.messagesState) == .unavailable)

        store.replaceMessages([])

        #expect(PickyConversationJournalPresentation(state: store.messagesState) == .empty)
    }

    /// Strict deterministic ownership gate. Unlike mounted-host body counts,
    /// Observation invalidation is independent of AppKit layout re-evaluation.
    @Test func replacingOneMessagePreservesMembershipTurnIdentityAndLeavesUnrelatedMessageLeafUnobserved() {
        let conversation = PickyConversationStore()
        let first = conversation.messageStore(message: message(id: "first", kind: .userText, text: "Streaming"))
        let second = conversation.messageStore(message: message(id: "second", text: "Stable"))
        let firstInvalidations = ConversationProjectionInvalidationCounter()
        let secondInvalidations = ConversationProjectionInvalidationCounter()

        withObservationTracking { _ = first.messageState } onChange: {
            firstInvalidations.increment()
        }
        withObservationTracking { _ = second.messageState } onChange: {
            secondInvalidations.increment()
        }
        let initialGroups = turnGroups(from: conversation)
        #expect(initialGroups.first?.userMessage?.id == first.messageID)

        let replacement = conversation.messageStore(message: message(id: "first", kind: .userText, text: "Complete"))
        let replacementGroups = turnGroups(from: conversation)

        #expect(replacement === first)
        #expect(conversation.orderedMessageIDs == ["first", "second"])
        #expect(initialGroups.map(\.id) == replacementGroups.map(\.id))
        #expect(firstInvalidations.count == 1)
        #expect(secondInvalidations.count == 0)
    }

    @Test func childProjectionsObserveOnlyTheirDeclaredOwners() {
        let card = sessionCard(messages: [message(id: "message-a", text: "Streaming")])
        let metadata = PickySessionMetaStore()
        metadata.replace(PickySessionMetadata(card: card))
        let conversation = PickyConversationStore()
        conversation.replaceMessages([message(id: "message-a", text: "Streaming")])
        let queue = PickySessionQueueStore()
        queue.markUnavailable()
        let artifacts = PickySessionArtifactStore()
        artifacts.markUnavailable()

        let headerInvalidations = ConversationProjectionInvalidationCounter()
        withObservationTracking { _ = PickyConversationHeaderProjection(metaStore: metadata) } onChange: {
            headerInvalidations.increment()
        }
        conversation.messageStore(message: message(id: "message-a", text: "Completed"))
        #expect(headerInvalidations.count == 0)
        metadata.replace(PickySessionMetadata(card: card))
        #expect(headerInvalidations.count == 1)

        let composerInvalidations = ConversationProjectionInvalidationCounter()
        withObservationTracking {
            _ = PickyConversationComposerProjection(
                metaStore: metadata,
                conversationStore: conversation,
                queueStore: queue
            )
        } onChange: {
            composerInvalidations.increment()
        }
        artifacts.markUnavailable()
        #expect(composerInvalidations.count == 0)
        conversation.messageStore(message: message(id: "message-a", text: "Final"))
        #expect(composerInvalidations.count == 1)

        let contextInvalidations = ConversationProjectionInvalidationCounter()
        withObservationTracking { _ = PickyConversationContextProjection(metaStore: metadata, artifactStore: artifacts) } onChange: {
            contextInvalidations.increment()
        }
        conversation.messageStore(message: message(id: "message-a", text: "Ignored by context"))
        #expect(contextInvalidations.count == 0)
        metadata.replace(PickySessionMetadata(card: card))
        #expect(contextInvalidations.count == 1)
    }

    /// Supplementary positive control only. AppKit layout may re-evaluate sibling
    /// bodies independently of data ownership, so exact body counts are not a CI
    /// contract. The deterministic sibling-isolation gate is the Observation test above.
    @Test func mountedConversationListDeliversReplacementToRelatedStableMessageLeaf() {
        let first = message(id: "message-a", kind: .userText, text: "Streaming")
        let second = message(id: "message-b", text: "Stable sibling")
        let conversation = PickyConversationStore()
        conversation.replaceMessages([first, second])
        let listEvaluations = ConversationProjectionInvalidationCounter()
        let firstLeafEvaluations = ConversationProjectionInvalidationCounter()
        let card = sessionCard(messages: [first, second], id: "conversation-mounted-stable-leaf")
        let viewModel = PickyProjectionReplayFixtures.makeViewModel()
        let host = NSHostingView(rootView: AnyView(PickyConversationListView(
            session: card,
            viewModel: viewModel,
            conversationStore: conversation,
            onBodyEvaluation: { listEvaluations.increment() },
            onMessageLeafBodyEvaluation: { id, _, _ in
                if id == first.id { firstLeafEvaluations.increment() }
            }
        )))
        defer { dismantleMountedHost(host) }
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        #expect(waitForMountedHost(host) {
            listEvaluations.count > 0 && firstLeafEvaluations.count > 0
        })

        let initialListEvaluations = listEvaluations.count
        let initialFirstLeafEvaluations = firstLeafEvaluations.count

        conversation.messageStore(message: message(id: first.id, kind: .userText, text: "Completed"))
        #expect(waitForMountedHost(host) {
            listEvaluations.count > initialListEvaluations
                && firstLeafEvaluations.count > initialFirstLeafEvaluations
        })
    }

    @Test func mountedConversationListRefreshesLatestResponseAndCommandHintWhenTheirInputsChange() {
        let first = message(id: "message-a", text: "```swift\nlet old = true\n```")
        let conversation = PickyConversationStore()
        conversation.replaceMessages([first])
        let leafEvaluations = ConversationProjectionMessageEvaluationRecorder()
        let state = ConversationProjectionMountedListState(session: sessionCard(messages: [first], id: "conversation-mounted-latest-response"))
        let host = NSHostingView(rootView: AnyView(MountedConversationProjectionList(
            state: state,
            conversationStore: conversation,
            viewModel: PickyProjectionReplayFixtures.makeViewModel(),
            onMessageLeafBodyEvaluation: leafEvaluations.record
        )))
        defer { dismantleMountedHost(host) }
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        #expect(waitForMountedHost(host) {
            leafEvaluations.count(for: first.id) > 0
                && leafEvaluations.contains(
                    messageID: first.id,
                    isLatestAgentResponse: true,
                    isLatestResponseShortcutHintVisible: false
                )
        })

        let initialFirstEvaluations = leafEvaluations.count(for: first.id)
        let second = message(id: "message-b", text: "Latest response")
        conversation.messageStore(message: second)
        state.session = sessionCard(messages: [first, second])

        #expect(waitForMountedHost(host) {
            leafEvaluations.count(for: first.id) > initialFirstEvaluations
                && leafEvaluations.count(for: second.id) > 0
                && leafEvaluations.contains(
                    messageID: first.id,
                    isLatestAgentResponse: false,
                    isLatestResponseShortcutHintVisible: false
                )
                && leafEvaluations.contains(
                    messageID: second.id,
                    isLatestAgentResponse: true,
                    isLatestResponseShortcutHintVisible: false
                )
        })

        let initialSecondEvaluations = leafEvaluations.count(for: second.id)
        state.isCommandShortcutHintVisible = true
        #expect(waitForMountedHost(host) {
            leafEvaluations.count(for: second.id) > initialSecondEvaluations
                && leafEvaluations.contains(
                    messageID: second.id,
                    isLatestAgentResponse: true,
                    isLatestResponseShortcutHintVisible: true
                )
        })
    }

    private func turnGroups(from conversation: PickyConversationStore) -> [PickyTurnGroup] {
        let messages = conversation.orderedMessageIDs.compactMap { id -> PickySessionMessage? in
            guard case .loaded(let message) = conversation.messageStore(id: id).messageState else { return nil }
            return message
        }
        return PickyTurnGrouper.groups(from: messages, sessionStatus: .running)
    }

    private func waitForMountedHost<Root: View>(
        _ host: NSHostingView<Root>,
        timeout: TimeInterval = 1,
        until condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
        host.layoutSubtreeIfNeeded()
        return condition()
    }

    private func dismantleMountedHost(_ host: NSHostingView<AnyView>) {
        host.rootView = AnyView(EmptyView())
        host.frame = .zero
        host.layoutSubtreeIfNeeded()
    }

    private func sessionCard(
        messages: [PickySessionMessage],
        id: String = "conversation-mounted-host"
    ) -> PickySessionListViewModel.SessionCard {
        PickySessionListViewModel.SessionCard.fromAgentSession(PickyAgentSession(
            id: id,
            title: "Conversation projection",
            status: .running,
            cwd: "/tmp/picky",
            createdAt: PickyProjectionReplayFixtures.terminalDate,
            updatedAt: PickyProjectionReplayFixtures.terminalDate,
            lastSummary: "",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: [],
            messages: messages,
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            activitySummary: .zero,
            contextUsage: nil,
            pendingExtensionUiRequest: nil,
            notifyMainOnCompletion: nil
        ))
    }

    private func message(id: String, kind: PickySessionMessageKind = .agentText, text: String) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: kind,
            createdAt: PickyProjectionReplayFixtures.terminalDate,
            originatedBy: .mainAgent,
            text: text,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            errorContext: nil,
            errorMessage: nil
        )
    }
}

@MainActor
@Observable
private final class ConversationProjectionMountedListState {
    var session: PickyConversationSessionCard
    var isCommandShortcutHintVisible = false

    init(session: PickyConversationSessionCard) {
        self.session = session
    }
}

@MainActor
private struct MountedConversationProjectionList: View {
    let state: ConversationProjectionMountedListState
    let conversationStore: PickyConversationStore
    let viewModel: any PickySessionCommands
    let onMessageLeafBodyEvaluation: (String, Bool, Bool) -> Void

    var body: some View {
        PickyConversationListView(
            session: state.session,
            viewModel: viewModel,
            conversationStore: conversationStore,
            isCommandShortcutHintVisible: state.isCommandShortcutHintVisible,
            onMessageLeafBodyEvaluation: onMessageLeafBodyEvaluation
        )
    }
}

private final class ConversationProjectionMessageEvaluationRecorder: @unchecked Sendable {
    private struct Evaluation {
        let messageID: String
        let isLatestAgentResponse: Bool
        let isLatestResponseShortcutHintVisible: Bool
    }

    private let lock = NSLock()
    private var evaluations: [Evaluation] = []

    func record(
        _ messageID: String,
        _ isLatestAgentResponse: Bool,
        _ isLatestResponseShortcutHintVisible: Bool
    ) {
        lock.withLock {
            evaluations.append(Evaluation(
                messageID: messageID,
                isLatestAgentResponse: isLatestAgentResponse,
                isLatestResponseShortcutHintVisible: isLatestResponseShortcutHintVisible
            ))
        }
    }

    func count(for messageID: String) -> Int {
        lock.withLock { evaluations.count { $0.messageID == messageID } }
    }

    func contains(
        messageID: String,
        isLatestAgentResponse: Bool,
        isLatestResponseShortcutHintVisible: Bool
    ) -> Bool {
        lock.withLock {
            evaluations.contains {
                $0.messageID == messageID
                    && $0.isLatestAgentResponse == isLatestAgentResponse
                    && $0.isLatestResponseShortcutHintVisible == isLatestResponseShortcutHintVisible
            }
        }
    }
}

private final class ConversationProjectionInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() { lock.withLock { value += 1 } }
}
