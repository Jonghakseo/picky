//
//  PickyHUDDockGroupListStatePolicy.swift
//  Picky
//
//  Production seams for stateful dock-group list wiring. These keep emitted
//  publisher values, child hosting identity, and rail routing testable without
//  opening a macOS panel.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class PickyHUDDockGroupListSubscriptionOrchestrator {
    typealias Sync = (PickyHUDDockSnapshot, CGFloat) -> Void

    private let sync: Sync

    init(sync: @escaping Sync) {
        self.sync = sync
    }

    /// Use the Combine emission, not the `@Published` backing store which is
    /// still the previous value while a `willSet` publisher is firing.
    func receiveSnapshot(_ snapshot: PickyHUDDockSnapshot, fontScale: CGFloat) {
        sync(snapshot, fontScale)
    }

    /// Font changes retain the current snapshot but must use the scale emitted
    /// by the publisher for the same `willSet` reason.
    func receiveFontScale(_ fontScale: CGFloat, snapshot: PickyHUDDockSnapshot) {
        sync(snapshot, fontScale)
    }
}

final class PickyHUDDockGroupListHostingLifecycle<Hosting: AnyObject> {
    enum SyncResult {
        case created(Hosting)
        case retained(Hosting)
    }

    private(set) var groupID: String?
    private(set) var hosting: Hosting?
    private(set) var creationCount = 0

    func synchronize(groupID: String, makeHosting: () -> Hosting) -> SyncResult {
        if self.groupID == groupID, let hosting {
            return .retained(hosting)
        }
        let hosting = makeHosting()
        self.groupID = groupID
        self.hosting = hosting
        creationCount += 1
        return .created(hosting)
    }

    func tearDown() {
        groupID = nil
        hosting = nil
    }
}

enum PickyHUDDockGroupListOutsideDismissFramePolicy {
    /// The panel is anchored to `badgeFrames`, but outside dismissal belongs to
    /// the larger tile-plus-label interaction frame. Keeping both inputs here
    /// makes a regression to tile-only hit testing observable in tests.
    static func owningInteractionScreenFrame(
        openGroupID: String?,
        badgeFrames: [String: CGRect],
        interactionFrames: [String: CGRect],
        hudPanelFrame: CGRect
    ) -> CGRect? {
        _ = badgeFrames
        guard let openGroupID, let interactionFrame = interactionFrames[openGroupID] else { return nil }
        return PickyHUDDockGroupListScreenLayout.screenFrame(
            hudPanelFrame: hudPanelFrame,
            swiftUIOrigin: interactionFrame.origin,
            panelSize: interactionFrame.size
        )
    }
}

enum PickyHUDDockGroupActivationRoute: Equatable {
    case showFolderPicker(groupID: String)
    case toggleMemberList(groupID: String)
}

enum PickyHUDDockGroupActivationRouter {
    static func route(groupID: String, hasVisibleMembers: Bool) -> PickyHUDDockGroupActivationRoute {
        switch PickyHUDDockNewPicklePopoverPolicy.groupTileAction(hasVisibleMembers: hasVisibleMembers) {
        case .showFolderPicker: .showFolderPicker(groupID: groupID)
        case .toggleMemberList: .toggleMemberList(groupID: groupID)
        }
    }

    static func perform(
        groupID: String,
        hasVisibleMembers: Bool,
        showFolderPicker: (String) -> Void,
        toggleMemberList: (String) -> Void
    ) {
        switch route(groupID: groupID, hasVisibleMembers: hasVisibleMembers) {
        case .showFolderPicker(let groupID): showFolderPicker(groupID)
        case .toggleMemberList(let groupID): toggleMemberList(groupID)
        }
    }
}

@MainActor
final class PickyHUDDockGroupPickerRelay: ObservableObject {
    @Published private(set) var requestedGroupID: String?

    func request(groupID: String) {
        requestedGroupID = groupID
    }

    func consume() {
        requestedGroupID = nil
    }
}

enum PickyHUDDockGroupPickerRelayPresentation: Equatable {
    case targeted(groupID: String)
    case untargeted
    case deferred
}

enum PickyHUDDockGroupPickerRelayPolicy {
    /// A deleted target cannot retain its old group id. The ordinary dock add
    /// anchor remains available as a deliberate untargeted fallback.
    static func presentation(
        requestedGroupID: String?,
        renderedGroupIDs: Set<String>,
        hasUntargetedAddAnchor: Bool
    ) -> PickyHUDDockGroupPickerRelayPresentation {
        guard let requestedGroupID else { return .deferred }
        if renderedGroupIDs.contains(requestedGroupID) { return .targeted(groupID: requestedGroupID) }
        return hasUntargetedAddAnchor ? .untargeted : .deferred
    }
}

enum PickyHUDDockEmptyGroupDropCandidatePolicy {
    /// Only groups with no visible members take this empty-group path.
    static func candidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        topEntryCenters: [String: CGFloat]
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        slots.compactMap { slot in
            guard let groupID = slot.groupID,
                  let group = layout.group(withID: groupID),
                  !group.memberSessionIDs.contains(where: activeSessionIDs.contains),
                  let center = topEntryCenters["group:\(groupID)"]
            else { return nil }
            return .init(
                groupID: groupID,
                memberIndex: PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                    forVisibleIndex: 0,
                    memberSessionIDs: group.memberSessionIDs,
                    activeSessionIDs: activeSessionIDs
                ),
                center: center
            )
        }
    }
}

enum PickyHUDDockNonEmptyGroupDropCandidatePolicy {
    /// Filled folders retain their existing drop behavior through a separate
    /// path, so an empty-group regression guard cannot accidentally remove it.
    static func candidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        topEntryCenters: [String: CGFloat]
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        slots.compactMap { slot in
            guard let groupID = slot.groupID,
                  let group = layout.group(withID: groupID),
                  group.memberSessionIDs.contains(where: activeSessionIDs.contains),
                  let center = topEntryCenters["group:\(groupID)"]
            else { return nil }
            return .init(
                groupID: groupID,
                memberIndex: PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                    forVisibleIndex: 0,
                    memberSessionIDs: group.memberSessionIDs,
                    activeSessionIDs: activeSessionIDs
                ),
                center: center
            )
        }
    }
}
