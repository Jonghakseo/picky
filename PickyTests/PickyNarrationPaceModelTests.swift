import Foundation
import Testing
@testable import Picky

struct PickyNarrationPaceModelTests {
    @Test func scalarWeightsFollowCalibratedScriptRules() {
        #expect(PickyNarrationPaceModel.weight(of: "한".unicodeScalars.first!) == 2.5)
        #expect(PickyNarrationPaceModel.weight(of: "a".unicodeScalars.first!) == 1.0)
        #expect(PickyNarrationPaceModel.weight(of: "1".unicodeScalars.first!) == 3.5)
        #expect(PickyNarrationPaceModel.weight(of: " ".unicodeScalars.first!) == 0.2)
        #expect(PickyNarrationPaceModel.weight(of: ",".unicodeScalars.first!) == 0.5)
        #expect(PickyNarrationPaceModel.weight(of: "\u{0301}".unicodeScalars.first!) == 0.0)
    }

    @Test func weightedUnitsStripParentheticalsBeforeCounting() {
        #expect(
            PickyNarrationPaceModel.weightedUnits(forNarration: "경로를 확인하세요. (/Users/x/y)")
                == PickyNarrationPaceModel.weightedUnits(forNarration: "경로를 확인하세요.")
        )
    }

    @Test func mixedKoreanAndEnglishWeighsMoreThanSameLengthEnglish() {
        #expect(
            PickyNarrationPaceModel.weightedUnits(forNarration: "한a")
                > PickyNarrationPaceModel.weightedUnits(forNarration: "ab")
        )
    }
}
