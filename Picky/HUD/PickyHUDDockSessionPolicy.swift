//
//  PickyHUDDockSessionPolicy.swift
//  Picky
//
//  Lightweight dock projection and presentation decisions shared by the HUD.
//

import Combine
import Foundation

/// Lightweight dock handle with stable session identity. Registry-backed
/// handles resolve their values from the per-session dock store, so message,
/// tool, log, and artifact mutations never invalidate tiles. The card
/// initializer remains only as the v1 compatibility bridge until W9 cleanup.
@MainActor
struct PickyHUDDockSession: Equatable, Identifiable {
    let id: String
    private let sessionStore: PickySessionStore?
    private let fallbackProjection: PickySessionDockProjection?

    init(store: PickySessionStore) {
        id = store.sessionID
        sessionStore = store
        fallbackProjection = nil
    }

    init(session: PickyConversationSessionCard) {
        id = session.id
        sessionStore = nil
        fallbackProjection = PickySessionDockProjection(
            metadata: PickySessionMetadata(card: session),
            todoState: session.todoState
        )
    }

    private var projection: PickySessionDockProjection {
        guard let projection = sessionStore?.dockStore.projection ?? fallbackProjection else {
            preconditionFailure("Dock session requires a loaded projection")
        }
        return projection
    }

    var title: String { projection.title }
    var status: PickySessionStatus { projection.status }
    var cwd: String? { projection.cwd }
    var todoState: PickyTodoState? { projection.todoState }
    var gitRefreshBucket: Int { projection.gitRefreshBucket }
    var previewUpdatedAt: Date { projection.previewUpdatedAt }
    var canRequestDockCompaction: Bool { projection.canRequestDockCompaction }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Registry-backed values preserve list identity across scalar updates;
        // individual icon views observe their own store for those updates.
        if lhs.sessionStore != nil || rhs.sessionStore != nil { return lhs.id == rhs.id }
        return lhs.id == rhs.id && lhs.fallbackProjection == rhs.fallbackProjection
    }

    var compactCwdDescription: String? {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardizedPath = NSString(string: trimmed).standardizingPath
        if standardizedPath == homePath { return "~" }
        if standardizedPath.hasPrefix(homePath + "/") {
            return "~" + String(standardizedPath.dropFirst(homePath.count))
        }
        return trimmed
    }
}

/// One replay-safe authoritative-membership removal. HUD owners consume the
/// revision once, so later snapshots cannot apply the same removal again.
struct PickyHUDDockRemovalEvent: Equatable {
    let revision: UInt64
    let sessionIDs: Set<String>
}

/// Every reactive value consumed by the HUD root and dock rail. The view model
/// owns one stable `PickyHUDDockState` instance and replaces this value only
/// after a logically complete mutation has settled.
struct PickyHUDDockSnapshot: Equatable {
    let activeSessions: [PickyHUDDockSession]
    let dockLayout: PickyDockLayout
    let screenContextTargetSessionID: String?
    let screenContextTargetSticky: Bool
    let screenContextArmCollapseToken: UUID
    let pendingDoneFlashSessionIDs: Set<String>
    let unreadSessionIDs: Set<String>
    let pinnedPickleCwds: [String]
    let recentPickleCwds: [String]
    let isLoadingInitialSessionSnapshot: Bool
    let openSessionRequest: PickyHUDOpenSessionRequest?
    /// Router-validated authoritative removals for HUD-local owners.
    let authoritativeRemovalEvent: PickyHUDDockRemovalEvent?

    static let empty = Self(
        activeSessions: [],
        dockLayout: .empty,
        screenContextTargetSessionID: nil,
        screenContextTargetSticky: false,
        screenContextArmCollapseToken: UUID(),
        pendingDoneFlashSessionIDs: [],
        unreadSessionIDs: [],
        pinnedPickleCwds: [],
        recentPickleCwds: [],
        isLoadingInitialSessionSnapshot: true,
        openSessionRequest: nil,
        authoritativeRemovalEvent: nil
    )
}

@MainActor
final class PickyHUDDockState: ObservableObject {
    @Published private(set) var snapshot: PickyHUDDockSnapshot

    init(snapshot: PickyHUDDockSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func publish(_ snapshot: PickyHUDDockSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}

extension PickySessionCard {
    var canRequestDockCompaction: Bool {
        guard !isCompacting else { return false }
        switch status {
        case .completed, .blocked, .failed, .cancelled:
            return true
        case .queued, .running, .waiting_for_input:
            return false
        }
    }

}
