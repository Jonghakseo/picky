//
//  PickyHUDDockGroupActivation.swift
//  Picky
//

import Combine
import Foundation

@MainActor
enum PickyHUDDockGroupActivationSource: Equatable {
    case pointer
    case commandShortcut
}

enum PickyHUDDockGroupActivationRoute: Equatable {
    case showFolderPicker(groupID: String)
    case openSession(sessionID: String)
    case toggleMemberList(groupID: String)
    case noAction
}

/// Shared entry coordinator for pointer and keyboard activation. A one-Pickle
/// group opens that Pickle directly; larger groups retain hover disclosure and
/// keyboard-pinned member-list behavior.
@MainActor
final class PickyHUDDockGroupActivationCoordinator {
    typealias VisibleMemberResolver = (String) -> [String]
    typealias PickerPresenter = (String) -> Void
    typealias SessionOpener = (String) -> Void
    typealias ListToggler = (String) -> Void

    private let visibleMemberIDs: VisibleMemberResolver
    private let showFolderPicker: PickerPresenter
    private let openSession: SessionOpener
    private let toggleMemberList: ListToggler

    init(
        visibleMemberIDs: @escaping VisibleMemberResolver,
        showFolderPicker: @escaping PickerPresenter,
        openSession: @escaping SessionOpener,
        toggleMemberList: @escaping ListToggler
    ) {
        self.visibleMemberIDs = visibleMemberIDs
        self.showFolderPicker = showFolderPicker
        self.openSession = openSession
        self.toggleMemberList = toggleMemberList
    }

    func activateFromPointer(groupID: String) {
        activate(groupID: groupID, source: .pointer)
    }

    func activateFromCommandShortcut(groupID: String) {
        activate(groupID: groupID, source: .commandShortcut)
    }

    func activate(groupID: String, source: PickyHUDDockGroupActivationSource) {
        switch Self.route(
            groupID: groupID,
            visibleMemberIDs: visibleMemberIDs(groupID),
            source: source
        ) {
        case .showFolderPicker(let groupID): showFolderPicker(groupID)
        case .openSession(let sessionID): openSession(sessionID)
        case .toggleMemberList(let groupID): toggleMemberList(groupID)
        case .noAction: break
        }
    }

    static func route(
        groupID: String,
        visibleMemberIDs: [String],
        source: PickyHUDDockGroupActivationSource
    ) -> PickyHUDDockGroupActivationRoute {
        switch PickyHUDDockGroupTilePresentation.resolve(visibleMemberIDs: visibleMemberIDs) {
        case .empty:
            return .showFolderPicker(groupID: groupID)
        case .singleSession(let sessionID):
            return .openSession(sessionID: sessionID)
        case .folder:
            switch source {
            case .pointer: return .noAction
            case .commandShortcut: return .toggleMemberList(groupID: groupID)
            }
        }
    }
}

struct PickyHUDDockGroupPickerRequest: Equatable, Identifiable {
    let id: UUID
    let groupID: String

    init(id: UUID = UUID(), groupID: String) {
        self.id = id
        self.groupID = groupID
    }
}

@MainActor
final class PickyHUDDockGroupPickerRelay: ObservableObject {
    @Published private(set) var request: PickyHUDDockGroupPickerRequest?

    func request(groupID: String) {
        request = PickyHUDDockGroupPickerRequest(groupID: groupID)
    }

    /// Only the exact popover request that reached an anchor may clear intent.
    /// An old popover appearing late cannot consume a newer request.
    func acknowledgePresentation(requestID: UUID) {
        guard request?.id == requestID else { return }
        request = nil
    }
}

enum PickyHUDDockGroupPickerPresentationIdentity {
    /// The popover closure captures this identity while it is bound to the
    /// active anchor. A later relay request cannot be acknowledged by an old
    /// anchor, including when an offscreen group uses the dock add fallback.
    static func requestID(
        forAnchorGroupID anchorGroupID: String?,
        activeAnchorGroupID: String?,
        activeRequest: PickyHUDDockGroupPickerRequest?
    ) -> UUID? {
        guard activeAnchorGroupID == anchorGroupID else { return nil }
        return activeRequest?.id
    }
}

enum PickyHUDDockGroupPickerRelayPresentation: Equatable {
    case targeted(groupID: String)
    /// The dock add button hosts the popover, but creation still targets the
    /// group from the original request.
    case untargeted(targetGroupID: String)
    case deferred
}

enum PickyHUDDockGroupPickerRelayPolicy {
    static func presentation(
        request: PickyHUDDockGroupPickerRequest?,
        renderedGroupIDs: Set<String>,
        hasUntargetedAddAnchor: Bool
    ) -> PickyHUDDockGroupPickerRelayPresentation {
        guard let request else { return .deferred }
        if renderedGroupIDs.contains(request.groupID) { return .targeted(groupID: request.groupID) }
        return hasUntargetedAddAnchor ? .untargeted(targetGroupID: request.groupID) : .deferred
    }
}
