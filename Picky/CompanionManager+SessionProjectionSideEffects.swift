//
//  CompanionManager+SessionProjectionSideEffects.swift
//  Picky
//

import Foundation

struct ProjectionSessionPresentation {
    var title: String
    var status: PickySessionStatus
    var lastSummary: String?

    init(session: PickyAgentSession) {
        title = session.title
        status = session.status
        lastSummary = session.lastSummary
    }
}

extension CompanionManager {
    func applySessionProjectionSnapshotSideEffects(_ snapshot: PickySessionProjectionSnapshot) {
        let session = snapshot.projection
        projectionSessionPresentations[session.id] = ProjectionSessionPresentation(session: session)
        handleSessionStatusTransition(session: session)
        updatePassiveAgentSummary(session.lastSummary ?? "\(session.title) · \(session.status.rawValue)")
    }

    func applySessionProjectionTransactionSideEffects(_ transaction: PickySessionProjectionTransaction) {
        var presentation = projectionSessionPresentations[transaction.sessionId]
        var shouldRefreshSummary = false

        for mutation in transaction.mutations {
            guard case .metaPatch(let patch) = mutation else { continue }
            if case .set(let status) = patch.status {
                handleSessionStatusTransition(sessionID: transaction.sessionId, status: status)
                presentation?.status = status
                shouldRefreshSummary = true
            }
            if case .set(let title) = patch.title {
                presentation?.title = title
                shouldRefreshSummary = true
            }
            switch patch.lastSummary {
            case .unchanged:
                break
            case .clear:
                presentation?.lastSummary = nil
                shouldRefreshSummary = true
            case .set(let summary):
                presentation?.lastSummary = summary
                updatePassiveAgentSummary(summary)
                shouldRefreshSummary = false
            }
        }

        if let presentation {
            projectionSessionPresentations[transaction.sessionId] = presentation
            if shouldRefreshSummary {
                updatePassiveAgentSummary(presentation.lastSummary ?? "\(presentation.title) · \(presentation.status.rawValue)")
            }
        }
    }
}
