//
//  PickyFullscreenConversationListView.swift
//  Picky
//
//  Scrollable LLM-chat transcript for the fullscreen workspace.
//

import SwiftUI

struct PickyFullscreenConversationListView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hasAppeared = false
    @State private var completedTurnIDsBySessionID: [String: Set<String>] = [:]

    private var turnGroups: [PickyTurnGroup] {
        PickyTurnGrouper.groups(
            from: session.messages,
            sessionStatus: session.status,
            liveActivitySummary: session.activitySummary
        )
    }

    private var turns: [PickyFullscreenTurnRenderModel] {
        PickyFullscreenTurnPolicy.renderModels(
            from: turnGroups,
            completedTurnIDs: completedTurnIDsBySessionID[session.id, default: []]
        )
    }

    private var completedTurnIDsToObserve: Set<String> {
        Set(turnGroups.filter { !$0.isCurrent }.map(\.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if turns.isEmpty {
                        emptyConversation
                    } else {
                        ForEach(turns) { turn in
                            PickyFullscreenTurnView(
                                turn: turn,
                                session: session,
                                viewModel: viewModel
                            )
                        }
                    }
                    PickyFullscreenChangedFilesCardView(changedFiles: session.changedFiles)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .task(id: session.id) {
                scrollToBottom(proxy: proxy, animated: false)
                hasAppeared = true
            }
            .onChange(of: bottomScrollTrigger) { _, _ in
                scrollToBottom(
                    proxy: proxy,
                    animated: Self.shouldAnimateScroll(hasAppeared: hasAppeared, reduceMotion: accessibilityReduceMotion)
                )
            }
        }
        .onAppear {
            observeCompletedTurns(completedTurnIDsToObserve)
        }
        .onChange(of: completedTurnIDsToObserve) { _, ids in
            observeCompletedTurns(ids)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation messages")
    }

    private func observeCompletedTurns(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        completedTurnIDsBySessionID[session.id, default: []].formUnion(ids)
    }

    private var emptyConversation: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No conversation yet")
                .font(.system(size: 16, weight: .semibold))
            Text("This Pickle has not recorded any chat messages yet.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No conversation yet")
        .accessibilityHint("This Pickle has not recorded any chat messages yet")
    }

    private var bottomScrollTrigger: PickyFullscreenConversationBottomScrollTrigger {
        PickyFullscreenConversationBottomScrollTrigger(
            latestMessageID: session.messages.last?.id,
            status: session.status,
            changedFilesCount: session.changedFiles.count,
            activitySummary: session.activitySummary
        )
    }

    static func shouldAnimateScroll(hasAppeared: Bool, reduceMotion: Bool) -> Bool {
        hasAppeared && !reduceMotion
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            } else {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchorID = "__picky_fullscreen_conversation_bottom_anchor__"
}

private struct PickyFullscreenConversationBottomScrollTrigger: Equatable {
    let latestMessageID: String?
    let status: PickySessionStatus
    let changedFilesCount: Int
    let activitySummary: PickyActivitySummary
}
