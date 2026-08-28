//
//  PickyHUDDockExternalDragPolicy.swift
//  Picky
//
//  Frozen geometry, structural validation, and terminal ownership for a
//  cross-panel Dock drag. This layer deliberately has no AppKit dependencies.
//

import CoreGraphics
import Foundation

struct PickyHUDDockExternalDragGeometrySnapshot: Equatable {
    let acceptanceFrame: CGRect
    let folderDropFrames: [String: CGRect]
    let slotCandidates: [PickyDockDropResolver.SlotCandidate]
    let topLevelInsertionCandidates: [PickyDockDropResolver.TopLevelInsertionCandidate]
    let groupCandidates: [PickyDockDropResolver.EmptyGroupCandidate]
    let dockSide: PickyHUDDockSide
    let geometryRevision: Int
    let slotPitch: CGFloat

    func containsUsableScreenPoint(_ point: CGPoint) -> Bool {
        point.x.isFinite
            && point.y.isFinite
            && acceptanceFrame.isFinite
            && acceptanceFrame.contains(point)
    }

    func axis(for screenPoint: CGPoint) -> CGFloat {
        switch dockSide.orientation {
        case .horizontal: screenPoint.x
        case .vertical: screenPoint.y
        }
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}

/// The minimal persisted structure that invalidates frozen external drag
/// geometry. Group labels and colors do not affect a target, while member
/// order, active membership, Dock side, and measured geometry do.
enum PickyHUDDockLayoutFingerprintEntry: Equatable {
    case session(String)
    case group(id: String, memberSessionIDs: [String])
}

struct PickyHUDDockLayoutFingerprint: Equatable {
    let entries: [PickyHUDDockLayoutFingerprintEntry]
    let activeSessionIDs: Set<String>
    let dockSide: PickyHUDDockSide
    let geometryRevision: Int

    init(
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        dockSide: PickyHUDDockSide,
        geometryRevision: Int
    ) {
        self.entries = layout.entries.map { entry in
            switch entry {
            case .session(let sessionID): .session(sessionID)
            case .group(let group): .group(id: group.id, memberSessionIDs: group.memberSessionIDs)
            }
        }
        self.activeSessionIDs = activeSessionIDs
        self.dockSide = dockSide
        self.geometryRevision = geometryRevision
    }
}

enum PickyHUDDockExternalDragDestinationResolver {
    /// Resolves only inside the frozen two-dimensional rail acceptance surface.
    /// The older resolver intentionally remains primary-axis-only, so it is
    /// called only after this policy has excluded panel gaps and transparent HUD.
    static func resolve(
        draggedSessionID: String,
        sourceGroupID: String,
        screenPoint: CGPoint,
        geometry: PickyHUDDockExternalDragGeometrySnapshot,
        layout: PickyDockLayout
    ) -> PickyDockContainer? {
        guard geometry.containsUsableScreenPoint(screenPoint) else { return nil }

        if let folderID = geometry.folderDropFrames.first(where: { _, frame in
            frame.isFinite && frame.contains(screenPoint)
        })?.key {
            guard folderID != sourceGroupID,
                  let candidate = geometry.groupCandidates.first(where: { $0.groupID == folderID }),
                  layout.group(withID: folderID) != nil
            else { return nil }
            return .group(id: candidate.groupID, memberIndex: candidate.memberIndex)
        }

        guard let destination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: draggedSessionID,
            cursorAxis: geometry.axis(for: screenPoint),
            slotCandidates: geometry.slotCandidates,
            topLevelInsertionCandidates: geometry.topLevelInsertionCandidates,
            // Group membership is accepted only by the exact screen-space
            // folder frames above. Outside those rectangles, even a matching
            // primary-axis coordinate is a top-level rail drop.
            emptyGroupCandidates: [],
            layout: layout,
            slotPitch: geometry.slotPitch
        ) else { return nil }

        switch destination {
        case .topLevel:
            return destination
        case .group(let groupID, _):
            guard groupID != sourceGroupID, layout.group(withID: groupID) != nil else { return nil }
            return destination
        }
    }
}

enum PickyHUDDockExternalDragCancellation: Equatable {
    case escape
    case invalidDrop
    case staleLayout
    case teardown
}

enum PickyHUDDockExternalDragTerminal: Equatable {
    case commit(PickyDockContainer)
    case cancel(PickyHUDDockExternalDragCancellation)
}

/// A token-scoped compare-and-set lease. Claiming a terminal effect removes
/// update ownership before the coordinator invokes its preview or persistence
/// boundary, making duplicate local/global release callbacks inert.
struct PickyHUDDockExternalDragState: Equatable {
    enum Phase: Equatable {
        case idle
        case dragging(UUID)
        case committing(UUID)
        case cancelling(UUID)
    }

    private(set) var phase: Phase = .idle

    mutating func begin(token: UUID) -> Bool {
        guard phase == .idle else { return false }
        phase = .dragging(token)
        return true
    }

    func acceptsUpdate(for token: UUID) -> Bool {
        phase == .dragging(token)
    }

    mutating func claimTerminal(
        token: UUID,
        outcome: PickyHUDDockExternalDragTerminal
    ) -> PickyHUDDockExternalDragTerminal? {
        guard phase == .dragging(token) else { return nil }
        switch outcome {
        case .commit:
            phase = .committing(token)
        case .cancel:
            phase = .cancelling(token)
        }
        return outcome
    }

    mutating func finishTerminal() {
        switch phase {
        case .committing, .cancelling:
            phase = .idle
        case .idle, .dragging:
            break
        }
    }
}
