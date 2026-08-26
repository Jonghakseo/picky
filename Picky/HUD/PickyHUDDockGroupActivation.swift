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
    case toggleMemberList(groupID: String)
}

/// Shared entry coordinator for the rail's primary click and the Command
/// shortcut. The source remains explicit so both production callers can be
/// independently regression tested while sharing membership routing.
@MainActor
final class PickyHUDDockGroupActivationCoordinator {
    typealias VisibleMemberResolver = (String) -> Bool
    typealias PickerPresenter = (String) -> Void
    typealias ListToggler = (String) -> Void

    private let hasVisibleMembers: VisibleMemberResolver
    private let showFolderPicker: PickerPresenter
    private let toggleMemberList: ListToggler

    init(
        hasVisibleMembers: @escaping VisibleMemberResolver,
        showFolderPicker: @escaping PickerPresenter,
        toggleMemberList: @escaping ListToggler
    ) {
        self.hasVisibleMembers = hasVisibleMembers
        self.showFolderPicker = showFolderPicker
        self.toggleMemberList = toggleMemberList
    }

    func activateFromPointer(groupID: String) {
        activate(groupID: groupID, source: .pointer)
    }

    func activateFromCommandShortcut(groupID: String) {
        activate(groupID: groupID, source: .commandShortcut)
    }

    func activate(groupID: String, source: PickyHUDDockGroupActivationSource) {
        _ = source
        switch Self.route(groupID: groupID, hasVisibleMembers: hasVisibleMembers(groupID)) {
        case .showFolderPicker(let groupID): showFolderPicker(groupID)
        case .toggleMemberList(let groupID): toggleMemberList(groupID)
        }
    }

    static func route(groupID: String, hasVisibleMembers: Bool) -> PickyHUDDockGroupActivationRoute {
        switch PickyHUDDockNewPicklePopoverPolicy.groupTileAction(hasVisibleMembers: hasVisibleMembers) {
        case .showFolderPicker: .showFolderPicker(groupID: groupID)
        case .toggleMemberList: .toggleMemberList(groupID: groupID)
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

enum PickyHUDDockGroupPickerRelayPresentation: Equatable {
    case targeted(groupID: String)
    case untargeted
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
        return hasUntargetedAddAnchor ? .untargeted : .deferred
    }
}
