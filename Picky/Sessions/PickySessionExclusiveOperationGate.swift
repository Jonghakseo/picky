//
//  PickySessionExclusiveOperationGate.swift
//  Picky
//
//  Serializes the per-session operations that must never interleave for one
//  session id: spawning its child daemon, deleting it, and renaming a Pickle
//  whose daemon is already gone.
//
//  The offline rename is the reason this exists. It asks the primary daemon to
//  rewrite stored metadata for a session no live daemon owns, so a child spawn
//  or a delete starting mid-write could resurrect or revive state the write was
//  based on. The gate refuses the second operation outright instead of queueing
//  it: a rename that silently waits behind a spawn would report success against
//  an owner that has changed underneath it.
//

import Foundation

@MainActor
final class PickySessionExclusiveOperationGate {
    enum Operation: String, Equatable {
        case spawnChild
        case delete
        case offlineRename
    }

    private var active: [String: Operation] = [:]

    func current(for sessionID: String) -> Operation? { active[sessionID] }

    func begin(_ operation: Operation, sessionID: String) throws {
        if let current = active[sessionID] {
            throw PickyCliSessionError.sessionOperationBusy(sessionId: sessionID, operation: current.rawValue)
        }
        active[sessionID] = operation
    }

    /// Releases only an entry this caller still owns, so a late `end` from a
    /// superseded operation cannot unlock someone else's section.
    func end(_ operation: Operation, sessionID: String) {
        guard active[sessionID] == operation else { return }
        active[sessionID] = nil
    }

    func run<T>(_ operation: Operation, sessionID: String, body: () async throws -> T) async throws -> T {
        try begin(operation, sessionID: sessionID)
        defer { end(operation, sessionID: sessionID) }
        return try await body()
    }
}
