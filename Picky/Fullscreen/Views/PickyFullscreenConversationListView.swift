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
    @ObservedObject private var snapshotStore: PickyFullscreenTurnSnapshotStore
    @StateObject private var turnDiffProvider = PickyFullscreenTurnDiffProvider()
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hasAppeared = false
    @State private var completedTurnIDsBySessionID: [String: Set<String>] = [:]
    @State private var expandedWorkSummaryTurnIDs: Set<String> = []

    init(session: PickySessionListViewModel.SessionCard, viewModel: PickySessionListViewModel) {
        self.session = session
        self.viewModel = viewModel
        _snapshotStore = ObservedObject(wrappedValue: viewModel.fullscreenTurnSnapshotStore)
    }

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
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            PickyFullscreenTurnView(
                                turn: turn,
                                session: session,
                                viewModel: viewModel,
                                isLastTurn: index == turns.index(before: turns.endIndex),
                                turnChangedFiles: changedFiles(for: turn, at: index),
                                usesSessionChangedFilesFallback: usesSessionChangedFilesFallback(for: turn, at: index),
                                isWorkSummaryExpanded: expandedWorkSummaryTurnIDs.contains(turn.id),
                                onToggleWorkSummary: { toggleWorkSummary(turnID: turn.id) }
                            )
                            .task(id: diffTaskID(for: turn, at: index)) {
                                await fetchTurnDiffIfNeeded(for: turn, at: index)
                            }
                        }
                    }
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
            turnDiffProvider.configure(cwd: session.cwd)
            observeCompletedTurns(completedTurnIDsToObserve)
        }
        .onChange(of: session.cwd) { _, cwd in
            turnDiffProvider.configure(cwd: cwd)
        }
        .onChange(of: completedTurnIDsToObserve) { _, ids in
            observeCompletedTurns(ids)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("대화 메시지")
    }

    private func observeCompletedTurns(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        completedTurnIDsBySessionID[session.id, default: []].formUnion(ids)
    }

    private func toggleWorkSummary(turnID: String) {
        if expandedWorkSummaryTurnIDs.contains(turnID) {
            expandedWorkSummaryTurnIDs.remove(turnID)
        } else {
            expandedWorkSummaryTurnIDs.insert(turnID)
        }
    }

    private func changedFiles(for turn: PickyFullscreenTurnRenderModel, at index: Int) -> [PickyChangedFile] {
        if let scoped = turnDiffProvider.diffsByTurnID[turn.id], !scoped.isEmpty {
            return scoped
        }
        if usesSessionChangedFilesFallback(for: turn, at: index) {
            return session.changedFiles
        }
        return []
    }

    private func usesSessionChangedFilesFallback(for turn: PickyFullscreenTurnRenderModel, at index: Int) -> Bool {
        snapshotStore.snapshot(sessionID: session.id, turnID: turn.id) == nil
            && PickyFullscreenTurnPolicy.shouldShowSessionChangedFilesCard(
                isLastTurn: index == turns.index(before: turns.endIndex),
                isCurrentTurn: turn.isCurrent,
                sessionStatus: session.status,
                changedFilesCount: session.changedFiles.count
            )
    }

    private func diffTaskID(for turn: PickyFullscreenTurnRenderModel, at index: Int) -> String {
        guard let startSnapshot = snapshotStore.snapshot(sessionID: session.id, turnID: turn.id), !turn.isCurrent else {
            return "\(session.id):\(turn.id):no-snapshot"
        }
        if let nextTurn = nextTurn(after: index), let endSnapshot = snapshotStore.snapshot(sessionID: session.id, turnID: nextTurn.id) {
            return "\(session.id):\(turn.id):\(startSnapshot.effectiveRef)..\(endSnapshot.effectiveRef)"
        }
        if index == turns.index(before: turns.endIndex) {
            return "\(session.id):\(turn.id):\(startSnapshot.effectiveRef)..latest:\(session.status.rawValue):\(session.updatedAt.timeIntervalSince1970)"
        }
        return "\(session.id):\(turn.id):waiting-for-next-snapshot"
    }

    private func fetchTurnDiffIfNeeded(for turn: PickyFullscreenTurnRenderModel, at index: Int) async {
        guard !turn.isCurrent,
              let startSnapshot = snapshotStore.snapshot(sessionID: session.id, turnID: turn.id) else { return }
        if let nextTurn = nextTurn(after: index), let endSnapshot = snapshotStore.snapshot(sessionID: session.id, turnID: nextTurn.id) {
            await turnDiffProvider.fetchDiff(
                turnID: turn.id,
                startRef: startSnapshot.effectiveRef,
                endRef: endSnapshot.effectiveRef
            )
        } else if index == turns.index(before: turns.endIndex) {
            await turnDiffProvider.fetchLastTurnDiff(turnID: turn.id, startRef: startSnapshot.effectiveRef)
        }
    }

    private func nextTurn(after index: Int) -> PickyFullscreenTurnRenderModel? {
        let nextIndex = turns.index(after: index)
        guard nextIndex < turns.endIndex else { return nil }
        return turns[nextIndex]
    }

    private var emptyConversation: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .pickyFont(size: 28, weight: .medium)
                .foregroundStyle(.secondary)
            Text("아직 대화가 없습니다")
                .pickyFont(size: 16, weight: .semibold)
            Text("이 Pickle에는 아직 기록된 대화 메시지가 없습니다.")
                .pickyFont(size: 13)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("아직 대화가 없습니다")
        .accessibilityHint("이 Pickle에는 아직 기록된 대화 메시지가 없습니다")
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
