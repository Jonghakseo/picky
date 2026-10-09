import CoreGraphics
import Testing
@testable import Picky

struct PickyHubPresentationDisplayPolicyTests {
    private let builtIn = PickyHubDisplayCandidate(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private let external = PickyHubDisplayCandidate(displayID: 2, bounds: CGRect(x: 1512, y: -300, width: 2560, height: 1440))
    private let third = PickyHubDisplayCandidate(displayID: 3, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

    @Test
    func requestedDisplayWithNormalSpaceKeepsTheHub() {
        // A zoomed window stops below the menu bar, so it is not full screen.
        let zoomed = CGRect(x: 1512, y: -275, width: 2560, height: 1415)
        let destination = PickyHubPresentationDisplayPolicy.destination(
            requested: 2,
            currentWindowDisplay: 1,
            displays: [builtIn, external],
            externalWindowFrames: [zoomed]
        )
        #expect(destination == 2)
    }

    @Test
    func fullScreenRequestedDisplayFallsBackToFirstNormalDisplay() {
        let destination = PickyHubPresentationDisplayPolicy.destination(
            requested: 2,
            currentWindowDisplay: nil,
            displays: [builtIn, external, third],
            externalWindowFrames: [external.bounds]
        )
        #expect(destination == 1)
    }

    @Test
    func fullScreenRequestedDisplayPrefersWhereTheHubAlreadyLives() {
        let destination = PickyHubPresentationDisplayPolicy.destination(
            requested: 2,
            currentWindowDisplay: 3,
            displays: [builtIn, external, third],
            externalWindowFrames: [external.bounds]
        )
        #expect(destination == 3)
    }

    @Test
    func everyDisplayInFullScreenKeepsTheRequest() {
        let destination = PickyHubPresentationDisplayPolicy.destination(
            requested: 2,
            currentWindowDisplay: 1,
            displays: [builtIn, external],
            externalWindowFrames: [builtIn.bounds, external.bounds]
        )
        #expect(destination == 2)
    }
}
