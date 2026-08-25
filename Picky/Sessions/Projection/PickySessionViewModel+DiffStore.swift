//
//  PickySessionViewModel+DiffStore.swift
//  Picky
//

import Foundation

extension PickySessionListViewModel {
    func sessionDiffState(for sessionID: String) -> PickySessionDiffState {
        sessionDiffStoresBySessionID[sessionID]?.state ?? PickySessionDiffState()
    }

    func sessionDiffStore(for sessionID: String) -> PickySessionDiffStore {
        if let existing = sessionDiffStoresBySessionID[sessionID] { return existing }
        let store = PickySessionDiffStore()
        sessionDiffStoresBySessionID[sessionID] = store
        return store
    }

    func setSessionDiffVisible(_ isVisible: Bool, sessionID: String) {
        if isVisible {
            guard visibleSessionDiffSessionIDs.insert(sessionID).inserted else { return }
            requestSessionDiff(sessionID: sessionID)
        } else {
            visibleSessionDiffSessionIDs.remove(sessionID)
        }
    }

    func selectSessionDiffView(_ view: PickySessionDiffView, sessionID: String) {
        guard sessionDiffState(for: sessionID).view != view else { return }
        requestSessionDiff(sessionID: sessionID, view: view)
    }

    func requestSessionDiff(sessionID: String, view requestedView: PickySessionDiffView? = nil) {
        guard card(sessionID: sessionID) != nil else { return }
        let view = requestedView ?? sessionDiffState(for: sessionID).view
        let requestID = "session-diff-\(UUID().uuidString)"
        let command = PickyCommandEnvelope(PickySessionDiffCommand(sessionId: sessionID, requestId: requestID, view: view))
        let store = sessionDiffStore(for: sessionID)
        store.replace(.requesting(view: view, requestID: requestID))
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.send(command)
            } catch {
                guard var state = self.sessionDiffStoresBySessionID[sessionID]?.state,
                      state.requestID == requestID else { return }
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                state.requestID = nil
                state.hasReceivedResult = true
                self.sessionDiffStoresBySessionID[sessionID]?.replace(state)
            }
        }
    }
}
