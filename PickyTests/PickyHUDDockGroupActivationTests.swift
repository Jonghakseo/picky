//
//  PickyHUDDockGroupActivationTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@MainActor
struct PickyHUDDockGroupActivationTests {
    @Test func emptyGroupsCreatePicklesSingleGroupsOpenDirectlyAndLargerGroupsDiscloseMembers() {
        var visibleMemberIDs: [String] = []
        var pickerGroups: [String] = []
        var openedSessions: [String] = []
        var listGroups: [String] = []
        let coordinator = PickyHUDDockGroupActivationCoordinator(
            visibleMemberIDs: { _ in visibleMemberIDs },
            showFolderPicker: { pickerGroups.append($0) },
            openSession: { openedSessions.append($0) },
            toggleMemberList: { listGroups.append($0) }
        )

        coordinator.activateFromPointer(groupID: "group")
        coordinator.activateFromCommandShortcut(groupID: "group")
        visibleMemberIDs = ["only"]
        coordinator.activateFromPointer(groupID: "group")
        coordinator.activateFromCommandShortcut(groupID: "group")
        visibleMemberIDs = ["first", "second"]
        coordinator.activateFromPointer(groupID: "group")
        coordinator.activateFromCommandShortcut(groupID: "group")

        #expect(pickerGroups == ["group", "group"])
        #expect(openedSessions == ["only", "only"])
        #expect(listGroups == ["group"])
    }

    @Test func relayRetainsIntentUntilTheMatchingPopoverAcknowledgesIt() {
        let relay = PickyHUDDockGroupPickerRelay()
        relay.request(groupID: "group")
        guard let firstRequest = relay.request else {
            Issue.record("Expected first request")
            return
        }
        #expect(PickyHUDDockGroupPickerRelayPolicy.presentation(
            request: firstRequest,
            renderedGroupIDs: ["group"],
            hasUntargetedAddAnchor: true
        ) == .targeted(groupID: "group"))

        relay.request(groupID: "group")
        guard let replacementRequest = relay.request else {
            Issue.record("Expected replacement request")
            return
        }
        relay.acknowledgePresentation(requestID: firstRequest.id)
        #expect(relay.request == replacementRequest)
        relay.acknowledgePresentation(requestID: replacementRequest.id)
        #expect(relay.request == nil)
    }

    @Test func anchorCapturesTheExactPresentationIdentityBeforeARelayReplacement() {
        let first = PickyHUDDockGroupPickerRequest(id: UUID(), groupID: "group")
        let replacement = PickyHUDDockGroupPickerRequest(id: UUID(), groupID: "group")
        let capturedID = PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: "group",
            activeAnchorGroupID: "group",
            activeRequest: first
        )

        #expect(capturedID == first.id)
        #expect(capturedID != replacement.id)
        #expect(PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: "other",
            activeAnchorGroupID: "group",
            activeRequest: replacement
        ) == nil)
    }

    @Test func dockAnchorFallbackCapturesRequestIdentityAndPreservesCreationTarget() {
        let request = PickyHUDDockGroupPickerRequest(groupID: "offscreen")

        #expect(PickyHUDDockGroupPickerRelayPolicy.presentation(
            request: request,
            renderedGroupIDs: [],
            hasUntargetedAddAnchor: true
        ) == .untargeted(targetGroupID: "offscreen"))
        #expect(PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: nil,
            activeAnchorGroupID: nil,
            activeRequest: request
        ) == request.id)
        #expect(PickyHUDDockGroupPickerRelayPolicy.presentation(
            request: request,
            renderedGroupIDs: [],
            hasUntargetedAddAnchor: false
        ) == .deferred)
    }
}
