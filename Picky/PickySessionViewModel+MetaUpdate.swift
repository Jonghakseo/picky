//
//  PickySessionViewModel+MetaUpdate.swift
//  Picky
//
//  Patch-driven `sessionMetaUpdated` handling, split out of
//  PickySessionViewModel.swift.
//

import Foundation

extension PickySessionListViewModel {
    /// Merges a patch-driven update without allowing its intentionally omitted
    /// conversation fields to replace a hydrated/incremental conversation.
    /// A meta event that races ahead of the initial session snapshot cannot
    /// establish a card because it does not carry the journal. Terminal events
    /// are retained until hydration so their live notification is not lost.
    func applySessionMetaUpdated(_ session: PickyAgentSession) {
        guard let previousCard = (sessions + archivedSessions).first(where: { $0.id == session.id }) else {
            if session.status.isTerminal {
                pendingTerminalMetaBySessionID[session.id] = session
                pickySessionLog("session terminal meta pending hydration session=\(session.id) status=\(session.status.rawValue)")
            } else {
                pendingTerminalMetaBySessionID.removeValue(forKey: session.id)
                pickySessionLog("session meta ignored before hydration session=\(session.id) status=\(session.status.rawValue)")
            }
            return
        }
        PickyPerf.event("vm_event_session_meta_updated")
        pickySessionLog("session meta updated session=\(session.id) status=\(session.status.rawValue)")
        var incomingCard = PickyPerf.interval("vm_session_meta_from_agent_session") {
            SessionCard.fromAgentSession(session)
        }
        // These are owned by ordered granular events while a session is live.
        // Carrying the existing projection also prevents a metadata event from
        // looking like a fresh empty Pi session when it omits `messages`,
        // `logs`, and `tools`.
        incomingCard.messages = previousCard.messages
        incomingCard.tools = previousCard.tools
        incomingCard.logPreview = previousCard.logPreview
        incomingCard.lastRequestText = previousCard.lastRequestText
        incomingCard.lastRequestAt = previousCard.lastRequestAt
        if session.piSessionFilePath == nil {
            incomingCard.piSessionFilePath = previousCard.piSessionFilePath
        }
        incomingCard.hasRuntimeDetachedFollowUpRejection = previousCard.hasRuntimeDetachedFollowUpRejection
        incomingCard.isMainAgentHandoff = previousCard.isMainAgentHandoff
        incomingCard.queuedSteers = previousCard.queuedSteers
        incomingCard.queuedFollowUps = previousCard.queuedFollowUps
        incomingCard.steeringMode = previousCard.steeringMode
        incomingCard.followUpMode = previousCard.followUpMode
        incomingCard.activitySummary = previousCard.activitySummary
        reconcileTodoProgressExpansion(
            sessionID: session.id,
            previousState: previousCard.todoState,
            currentState: incomingCard.todoState
        )
        reconcileSubagentInvocationExpansion(
            sessionID: session.id,
            messages: incomingCard.messages,
            previousRuns: previousCard.subagentRuns,
            currentRuns: incomingCard.subagentRuns
        )
        if shouldInvalidateSlashCommandCache(previous: previousCard, incoming: incomingCard) {
            invalidateSlashCommandCache(sessionID: session.id)
        }
        PickyPerf.interval("vm_event_session_meta_updated_upsert") {
            upsert(incomingCard, preserveIncrementalConversationState: true)
        }
        if visibleSessionDiffSessionIDs.contains(session.id),
           PickySessionDiffPresentation.isSettledTransition(from: previousCard.status, to: incomingCard.status) {
            requestSessionDiff(sessionID: session.id)
        }
    }

    /// Replays a terminal metadata event that arrived before hydration, but
    /// only when it is fresher than the hydrated card so a stale terminal
    /// status can never roll back a newer running state.
    func applyPendingTerminalMetaIfNeeded(for sessionID: String) {
        guard let pendingTerminalMeta = pendingTerminalMetaBySessionID.removeValue(forKey: sessionID),
              let hydratedCard = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              pendingTerminalMeta.updatedAt > hydratedCard.updatedAt else { return }
        applySessionMetaUpdated(pendingTerminalMeta)
    }
}
