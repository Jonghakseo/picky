//
//  PickyHUDDockGroupActivationTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@MainActor
struct PickyHUDDockGroupActivationTests {
    @Test func pointerAndCommandUseDistinctProductionEntriesWithSharedRouting() {
        var hasVisibleMembers = false
        var pickerGroups: [String] = []
        var listGroups: [String] = []
        let coordinator = PickyHUDDockGroupActivationCoordinator(
            hasVisibleMembers: { _ in hasVisibleMembers },
            showFolderPicker: { pickerGroups.append($0) },
            toggleMemberList: { listGroups.append($0) }
        )

        coordinator.activateFromPointer(groupID: "group")
        coordinator.activateFromCommandShortcut(groupID: "group")
        hasVisibleMembers = true
        coordinator.activateFromPointer(groupID: "group")

        #expect(pickerGroups == ["group", "group"])
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

    @Test func deletedPickerTargetFallsBackWithoutSilentlyConsumingIntent() {
        let request = PickyHUDDockGroupPickerRequest(groupID: "deleted")
        #expect(PickyHUDDockGroupPickerRelayPolicy.presentation(
            request: request,
            renderedGroupIDs: [],
            hasUntargetedAddAnchor: true
        ) == .untargeted)
        #expect(PickyHUDDockGroupPickerRelayPolicy.presentation(
            request: request,
            renderedGroupIDs: [],
            hasUntargetedAddAnchor: false
        ) == .deferred)
    }
}
