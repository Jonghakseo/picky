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
    /// The complete persisted layout state that was present when these screen
    /// coordinates were measured. Geometry must never be reused for a newer
    /// structure merely because its side and revision happen to match.
    let layoutFingerprint: PickyHUDDockLayoutFingerprint
    let slotPitch: CGFloat

    func containsUsableScreenPoint(_ point: CGPoint) -> Bool {
        point.x.isFinite
            && point.y.isFinite
            && acceptanceFrame.isFinite
            && acceptanceFrame.contains(point)
    }

    func axis(for screenPoint: CGPoint) -> CGFloat {
        PickyHUDDockExternalDragAxisPolicy.normalizedAxis(
            forScreenPoint: screenPoint,
            dockSide: dockSide
        )
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}

/// Rail measurements use SwiftUI's top-left HUD coordinate system. This pure
/// boundary converts the complete base-layout observation to AppKit screen
/// space only when Overlay Manager needs a frozen external-drag snapshot.
struct PickyHUDDockExternalDragRailGeometryInput {
    let slots: [PickyDockSlot]
    let slotCenters: [String: CGPoint]
    let topEntryIDs: [String]
    let topEntryAxisCenters: [String: CGFloat]
    let folderDropFrames: [String: CGRect]
    let layout: PickyDockLayout
    let activeSessionIDs: Set<String>
    let dockSide: PickyHUDDockSide
    let geometryRevision: Int
    let metrics: PickyHUDDockMetrics
    let fontScale: CGFloat

    func screenSnapshot(
        draggedSessionID: String,
        hudRailFrame: CGRect,
        hudPanelFrame: CGRect
    ) -> PickyHUDDockExternalDragGeometrySnapshot? {
        let renderedGroupIDs = Set(slots.compactMap(\.groupID))
        guard hudRailFrame.isFinite, hudRailFrame.width > 0, hudRailFrame.height > 0,
              topEntryIDs.allSatisfy({ topEntryAxisCenters[$0]?.isFinite == true }),
              slots.allSatisfy({ slot in
                  guard let sessionID = slot.sessionID else { return true }
                  guard let center = slotCenters[sessionID] else { return false }
                  return center.x.isFinite && center.y.isFinite
              }),
              renderedGroupIDs.allSatisfy({ groupID in
                  guard let frame = folderDropFrames[groupID] else { return false }
                  return frame.isFinite && frame.width > 0 && frame.height > 0
              })
        else { return nil }
        let fingerprint = PickyHUDDockLayoutFingerprint(
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            dockSide: dockSide,
            geometryRevision: geometryRevision
        )
        let screenSlotCenters = slotCenters.reduce(into: [String: CGPoint]()) { result, item in
            result[item.key] = PickyHUDDockExternalDragScreenLayout.screenPoint(
                hudPoint: CGPoint(
                    x: hudRailFrame.minX + item.value.x,
                    y: hudRailFrame.minY + item.value.y
                ),
                hudPanelFrame: hudPanelFrame
            )
        }
        let folderFrames = folderDropFrames.reduce(into: [String: CGRect]()) { result, item in
            let hudFrame = item.value.offsetBy(dx: hudRailFrame.minX, dy: hudRailFrame.minY)
            result[item.key] = PickyHUDDockExternalDragScreenLayout.screenFrame(
                hudFrame: hudFrame,
                hudPanelFrame: hudPanelFrame
            )
        }
        let screenTopEntryCenters = topEntryAxisCenters.reduce(into: [String: CGFloat]()) { result, item in
            result[item.key] = PickyHUDDockExternalDragScreenLayout.screenAxis(
                hudAxis: item.value + (dockSide.orientation == .horizontal ? hudRailFrame.minX : hudRailFrame.minY),
                dockSide: dockSide,
                hudPanelFrame: hudPanelFrame
            )
        }
        let topEntryCenters = screenTopEntryCenters.mapValues {
            PickyHUDDockExternalDragAxisPolicy.normalize(screenAxis: $0, dockSide: dockSide)
        }
        let screenSlots = slots.compactMap { slot -> PickyDockDropResolver.SlotCandidate? in
            guard let sessionID = slot.sessionID,
                  let container = slot.container,
                  let center = screenSlotCenters[sessionID]
            else { return nil }
            return .init(
                container: container,
                center: PickyHUDDockExternalDragAxisPolicy.normalizedAxis(
                    forScreenPoint: center,
                    dockSide: dockSide
                )
            )
        }
        let topLevelInsertionCandidates = PickyHUDDockExternalDragGeometryPolicy.topLevelInsertionCandidates(
            visibleTopEntryIDs: topEntryIDs,
            referenceCenters: topEntryCenters,
            draggedSessionID: draggedSessionID,
            layout: layout,
            slotPitch: PickyHUDDockDragGeometry.slotPitch(
                orientation: dockSide.orientation,
                metrics: metrics
            )
        )
        let groupCandidates = PickyHUDDockGroupDropCandidateBuilder.emptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: folderFrames,
            topEntryCenters: screenTopEntryCenters,
            orientation: dockSide.orientation,
            metrics: metrics,
            fontScale: fontScale
        ) + PickyHUDDockGroupDropCandidateBuilder.nonEmptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: folderFrames,
            topEntryCenters: screenTopEntryCenters,
            orientation: dockSide.orientation,
            metrics: metrics,
            fontScale: fontScale
        )
        return .init(
            acceptanceFrame: PickyHUDDockExternalDragScreenLayout.screenFrame(
                hudFrame: hudRailFrame,
                hudPanelFrame: hudPanelFrame
            ),
            folderDropFrames: folderFrames,
            slotCandidates: screenSlots,
            topLevelInsertionCandidates: topLevelInsertionCandidates,
            groupCandidates: groupCandidates,
            dockSide: dockSide,
            geometryRevision: geometryRevision,
            layoutFingerprint: fingerprint,
            slotPitch: PickyHUDDockDragGeometry.slotPitch(
                orientation: dockSide.orientation,
                metrics: metrics
            )
        )
    }
}

/// Converts physical screen coordinates to an axis that grows in persisted
/// Dock order. AppKit screen Y grows upward, opposite to vertical Dock order.
enum PickyHUDDockExternalDragAxisPolicy {
    static func normalizedAxis(forScreenPoint point: CGPoint, dockSide: PickyHUDDockSide) -> CGFloat {
        let screenAxis = dockSide.orientation == .horizontal ? point.x : point.y
        return normalize(screenAxis: screenAxis, dockSide: dockSide)
    }

    static func normalize(screenAxis: CGFloat, dockSide: PickyHUDDockSide) -> CGFloat {
        switch dockSide.orientation {
        case .horizontal: screenAxis
        case .vertical: -screenAxis
        }
    }
}

enum PickyHUDDockExternalDragScreenLayout {
    static func screenPoint(hudPoint: CGPoint, hudPanelFrame: CGRect) -> CGPoint {
        CGPoint(x: hudPanelFrame.minX + hudPoint.x, y: hudPanelFrame.maxY - hudPoint.y)
    }

    static func screenFrame(hudFrame: CGRect, hudPanelFrame: CGRect) -> CGRect {
        CGRect(
            x: hudPanelFrame.minX + hudFrame.minX,
            y: hudPanelFrame.maxY - hudFrame.maxY,
            width: hudFrame.width,
            height: hudFrame.height
        )
    }

    static func screenAxis(
        hudAxis: CGFloat,
        dockSide: PickyHUDDockSide,
        hudPanelFrame: CGRect
    ) -> CGFloat {
        switch dockSide.orientation {
        case .horizontal: hudPanelFrame.minX + hudAxis
        case .vertical: hudPanelFrame.maxY - hudAxis
        }
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

/// Candidate assembly used only by the external-drag path. Regular rail
/// reordering retains its established candidate set. Unlike session slots,
/// folder-only rails have no linear edge geometry, so expose two explicit
/// top-level targets around the frozen visible top-entry range.
enum PickyHUDDockExternalDragGeometryPolicy {
    static func topLevelInsertionCandidates(
        visibleTopEntryIDs: [String],
        referenceCenters: [String: CGFloat],
        draggedSessionID: String,
        layout: PickyDockLayout,
        slotPitch: CGFloat
    ) -> [PickyDockDropResolver.TopLevelInsertionCandidate] {
        let interior = PickyHUDDockRenderPolicy.topLevelInsertionCandidates(
            visibleTopEntryIDs: visibleTopEntryIDs,
            referenceCenters: referenceCenters,
            draggedSessionID: draggedSessionID,
            layout: layout
        )
        guard slotPitch.isFinite, slotPitch > 0,
              let firstID = visibleTopEntryIDs.first,
              let lastID = visibleTopEntryIDs.last,
              let firstCenter = referenceCenters[firstID], firstCenter.isFinite,
              let lastCenter = referenceCenters[lastID], lastCenter.isFinite,
              let firstIndex = PickyHUDDockRenderPolicy.layoutEntryIndex(
                forVisibleTopEntryID: firstID,
                in: layout
              ),
              let lastIndex = PickyHUDDockRenderPolicy.layoutEntryIndex(
                forVisibleTopEntryID: lastID,
                in: layout
              )
        else { return interior }

        return [
            .init(topLevelIndex: firstIndex, center: firstCenter - slotPitch),
        ] + interior + [
            .init(topLevelIndex: lastIndex + 1, center: lastCenter + slotPitch),
        ]
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

    /// Releases a begun drag that never acquired its required AppKit monitors.
    /// No preview or terminal effect is emitted for this failed promotion.
    mutating func abandon(token: UUID) {
        guard phase == .dragging(token) else { return }
        phase = .idle
    }
}
