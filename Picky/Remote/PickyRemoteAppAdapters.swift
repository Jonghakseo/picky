//
//  PickyRemoteAppAdapters.swift
//  Picky
//
//  Bridges between the remote hub and the app objects that own the actions a
//  phone can trigger. Each adapter exists so `Picky/Remote` depends on narrow
//  protocols instead of the view models themselves, and so tests can drive the
//  request handler with fakes.
//

import Combine
import Foundation

/// Everything `hub.overlay` needs, as one deduplicated stream.
@MainActor
protocol PickyRemoteOverlaySource: AnyObject {
    func currentRemoteOverlay() -> PickyRemoteOverlaySnapshot
    var remoteOverlayPublisher: AnyPublisher<PickyRemoteOverlaySnapshot, Never> { get }
}

/// Daemon endpoints the gateway connects to directly. All daemons share one token.
struct PickyRemoteDaemonTopology: Equatable {
    var token: String
    var primaryURL: String?
    var children: [PickyRemoteDaemonChild]

    var hubMessage: PickyHubToGatewayMessage {
        .daemons(
            token: token,
            primary: primaryURL.map { PickyRemoteDaemonEndpoint(url: $0) },
            children: children
        )
    }
}

@MainActor
protocol PickyRemoteDaemonTopologySource: AnyObject {
    func currentRemoteDaemonTopology() -> PickyRemoteDaemonTopology
    var remoteDaemonTopologyPublisher: AnyPublisher<PickyRemoteDaemonTopology, Never> { get }
}

// MARK: - Session list

extension PickySessionListViewModel: PickyRemoteOverlaySource, PickyRemoteSessionActions {
    func currentRemoteOverlay() -> PickyRemoteOverlaySnapshot {
        Self.remoteOverlay(
            dock: dockState.snapshot,
            archivedSessionIDs: archivedSessions.map(\.id)
        )
    }

    /// Built from the dock's own observation boundary so the hub never
    /// subscribes to the view model at large. The dock state republishes only
    /// after a logically complete mutation, which is exactly the cadence the
    /// phone needs.
    var remoteOverlayPublisher: AnyPublisher<PickyRemoteOverlaySnapshot, Never> {
        dockState.$snapshot
            .combineLatest(archivedSessionIDsPublisher)
            .map { dock, archived in
                Self.remoteOverlay(dock: dock, archivedSessionIDs: archived.sorted())
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private static func remoteOverlay(
        dock: PickyHUDDockSnapshot,
        archivedSessionIDs: [String]
    ) -> PickyRemoteOverlaySnapshot {
        PickyRemoteOverlayBuilder.build(
            activeSessionIDs: dock.activeSessions.map(\.id),
            archivedSessionIDs: archivedSessionIDs,
            unreadSessionIDs: dock.unreadSessionIDs,
            dockLayout: dock.dockLayout,
            pinnedFolders: dock.pinnedPickleCwds,
            recentFolders: dock.recentPickleCwds
        )
    }

    // MARK: PickyRemoteSessionActions

    /// `createEmptyPickleSession` spawns the child daemon and records the
    /// folder, but never selects a card or opens a panel, so the remote path
    /// can use it unchanged.
    func createRemotePickle(cwd: String) async throws -> String {
        try await createEmptyPickleSession(cwd: cwd)
    }

    func markRemoteSessionRead(sessionID: String) {
        markSessionRead(sessionID: sessionID)
    }

    func setRemoteSessionArchived(sessionID: String, archived: Bool) async throws {
        guard (sessions + archivedSessions).contains(where: { $0.id == sessionID }) else {
            throw PickyRemoteHubError(
                code: PickyRemoteHubErrorCode.invalidRequest,
                message: L10n.t("settings.remote.error.sessionMissing")
            )
        }
        if archived {
            try await archiveSessionConfirmed(sessionID: sessionID, mode: nil)
        } else {
            unarchive(sessionID: sessionID)
        }
    }
}

// MARK: - Daemon topology

/// Reads the daemon endpoints the router currently owns. Republished whenever
/// a child daemon is spawned or released.
@MainActor
final class PickyRemoteDaemonTopologyProvider: PickyRemoteDaemonTopologySource {
    private let pool: PickyAgentDaemonPool
    private let token: String
    private let primaryPort: Int

    init(pool: PickyAgentDaemonPool, token: String, primaryPort: Int) {
        self.pool = pool
        self.token = token
        self.primaryPort = primaryPort
    }

    func currentRemoteDaemonTopology() -> PickyRemoteDaemonTopology {
        topology(for: pool.activeChildSessionIds)
    }

    var remoteDaemonTopologyPublisher: AnyPublisher<PickyRemoteDaemonTopology, Never> {
        pool.$activeChildSessionIds
            .map { [weak self] ids in
                self?.topology(for: ids) ?? PickyRemoteDaemonTopology(token: "", primaryURL: nil, children: [])
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private func topology(for sessionIDs: Set<String>) -> PickyRemoteDaemonTopology {
        let children = sessionIDs.sorted().compactMap { sessionID -> PickyRemoteDaemonChild? in
            guard let endpoint = pool.endpoint(for: sessionID) else { return nil }
            return PickyRemoteDaemonChild(
                sessionId: sessionID,
                url: "ws://\(endpoint.host):\(endpoint.port)"
            )
        }
        return PickyRemoteDaemonTopology(
            token: token,
            primaryURL: "ws://127.0.0.1:\(primaryPort)",
            children: children
        )
    }
}
