//
//  PickySessionDockStore.swift
//  Picky
//

import Foundation
import Observation

/// The exact per-session fields rendered by a dock tile and its hover preview.
/// Conversation, tools, logs, and artifacts deliberately have no representation
/// here: a dock tile must not observe high-frequency session detail updates.
struct PickySessionDockProjection: Equatable {
    let id: String
    let title: String
    let status: PickySessionStatus
    let cwd: String?
    let todoState: PickyTodoState?
    /// Changes only at the legacy hover-preview Git refresh cadence, avoiding
    /// a dock publication for every metadata timestamp update.
    let gitRefreshBucket: Int
    var previewUpdatedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(gitRefreshBucket) * Self.gitRefreshBucketSeconds)
    }
    let canRequestDockCompaction: Bool

    init(metadata: PickySessionMetadata, todoState: PickyTodoState?) {
        id = metadata.id
        title = metadata.title
        status = metadata.status
        cwd = metadata.cwd
        self.todoState = todoState
        gitRefreshBucket = Int(metadata.updatedAt.timeIntervalSince1970 / Self.gitRefreshBucketSeconds)
        let isCompacting = status == .running
            && (metadata.lastSummary ?? "").localizedCaseInsensitiveContains("compacting")
        guard !isCompacting else {
            canRequestDockCompaction = false
            return
        }
        switch status {
        case .completed, .blocked, .failed, .cancelled:
            canRequestDockCompaction = true
        case .queued, .running, .waiting_for_input:
            canRequestDockCompaction = false
        }
    }

    private static let gitRefreshBucketSeconds: TimeInterval = 20
}

/// Stable, per-session observation owner for dock presentation. Equality guards
/// are important: v2 transactions refresh metadata after every mutation, but a
/// message-only mutation must leave every dock tile unobserved.
@MainActor
@Observable
final class PickySessionDockStore {
    private(set) var projection: PickySessionDockProjection?

    func replace(metadata: PickySessionMetadata, todoState: PickyTodoState?) {
        let next = PickySessionDockProjection(metadata: metadata, todoState: todoState)
        guard projection != next else { return }
        projection = next
    }

    func markUnavailable() {
        guard projection != nil else { return }
        projection = nil
    }
}
