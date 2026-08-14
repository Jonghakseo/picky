//
//  PickyHUDDockSessionPolicy.swift
//  Picky
//
//  Lightweight dock projection and presentation decisions shared by the HUD.
//

import Combine
import Foundation

/// Immutable, dock-only projection of a live session. Keep high-frequency
/// conversation details out of this value so tool, message, and log updates do
/// not invalidate every dock on every display.
struct PickyHUDDockSession: Equatable, Identifiable {
    let id: String
    let title: String
    let status: PickySessionStatus
    let cwd: String?
    let todoState: PickyTodoState?
    let canRequestDockCompaction: Bool

    init(session: PickySessionListViewModel.SessionCard) {
        id = session.id
        title = session.title
        status = session.status
        cwd = session.cwd
        todoState = session.todoState
        canRequestDockCompaction = session.canRequestDockCompaction
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
        openSessionRequest: nil
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

extension PickySessionListViewModel.SessionCard {
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
