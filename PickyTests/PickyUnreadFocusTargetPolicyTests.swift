import Testing
@testable import Picky

struct PickyUnreadFocusTargetPolicyTests {
    @Test func firstUnreadUsesFlattenedDockOrderIncludingGroupMembers() {
        let layout = PickyDockLayout(entries: [
            .session(id: "top"),
            .group(PickyDockGroup(id: "group", memberSessionIDs: ["member-a", "member-b"])),
            .session(id: "tail"),
        ])

        let target = PickyUnreadFocusTargetPolicy.targetSessionID(
            layout: layout,
            activeSessionIDs: ["tail", "member-b", "member-a", "top"],
            unreadSessionIDs: ["member-b", "tail"],
            lastActualConversationCardOpenedID: nil
        )

        #expect(target == "member-b")
    }

    @Test func fallsBackToLastActualOpenWhenNoUnreadExists() {
        let target = PickyUnreadFocusTargetPolicy.targetSessionID(
            layout: PickyDockLayout(entries: [.session(id: "first"), .session(id: "last")]),
            activeSessionIDs: ["first", "last"],
            unreadSessionIDs: [],
            lastActualConversationCardOpenedID: "last"
        )

        #expect(target == "last")
    }

    @Test func freshLaunchFallsBackToFirstActivePickle() {
        let target = PickyUnreadFocusTargetPolicy.targetSessionID(
            layout: PickyDockLayout(entries: [.group(PickyDockGroup(id: "group", memberSessionIDs: ["first", "second"]))]),
            activeSessionIDs: ["second", "first"],
            unreadSessionIDs: [],
            lastActualConversationCardOpenedID: nil
        )

        #expect(target == "first")
    }

    @Test func staleUnreadAndLastOpenAreIgnored() {
        let target = PickyUnreadFocusTargetPolicy.targetSessionID(
            layout: PickyDockLayout(entries: [
                .session(id: "archived"),
                .group(PickyDockGroup(id: "group", memberSessionIDs: ["deleted", "active"])),
            ]),
            activeSessionIDs: ["active"],
            unreadSessionIDs: ["archived", "deleted"],
            lastActualConversationCardOpenedID: "deleted"
        )

        #expect(target == "active")
    }

    @Test func returnsNilWhenNoActivePicklesExist() {
        #expect(PickyUnreadFocusTargetPolicy.targetSessionID(
            layout: .empty,
            activeSessionIDs: [],
            unreadSessionIDs: ["stale"],
            lastActualConversationCardOpenedID: "stale"
        ) == nil)
    }
}
