import Foundation
import Testing
@testable import Picky

struct PickyDockFolderGlyphPolicyTests {
    @Test func newestMembersComeFirstWithStableTiesAndMissingDatesLast() {
        let ids = ["missing", "older", "newer-a", "newer-b"]
        let dates = [
            "older": Date(timeIntervalSince1970: 1),
            "newer-a": Date(timeIntervalSince1970: 2),
            "newer-b": Date(timeIntervalSince1970: 2),
        ]
        #expect(PickyDockGroupRecencyPolicy.memberIDs(ids, updatedAtByID: dates)
            == ["newer-a", "newer-b", "older", "missing"])
    }

    @Test func folderShowsTheLeadingListMembersAndCountsTheRest() {
        let model = PickyHUDDockFolderBadgeViewModel(memberIDs: ["newest", "second", "third", "oldest"])
        #expect(model.glyphMemberIDs == ["newest", "second", "third"])
        #expect(model.overflowCount == 1)
    }

    @Test func emptyAndSmallGroupsHaveNoOverflow() {
        #expect(PickyHUDDockFolderBadgeViewModel(memberIDs: []).glyphMemberIDs.isEmpty)
        #expect(PickyHUDDockFolderBadgeViewModel(memberIDs: ["only"]).glyphMemberIDs == ["only"])
        #expect(PickyDockFolderGlyphPolicy.overflowCount(memberCount: 1, glyphCellCount: 3) == 0)
    }
}
