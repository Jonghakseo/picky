//
//  PickyHubModalTests.swift
//  PickyTests
//

import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHubModalTests {
    @Test func dismissalRestoresItsTriggerOnceAfterPresentationClears() {
        let host = PickyHubModalHost()
        var restorationCount = 0

        let firstID = host.present(accessibilityLabel: "First", onDismiss: { restorationCount += 1 }) {
            EmptyView()
        }
        host.dismiss()
        host.dismiss()

        #expect(host.presentation == nil)
        #expect(restorationCount == 0)

        host.presentationDidDisappear(id: firstID)
        host.presentationDidDisappear(id: firstID)

        #expect(restorationCount == 1)
    }

    @Test func replacementCleansUpTheDismissedPresentationWithoutRestoringItsFocus() {
        let host = PickyHubModalHost()
        var firstCleanupCount = 0
        var firstRestorationCount = 0
        var secondRestorationCount = 0

        let firstID = host.present(
            accessibilityLabel: "First",
            onWillDismiss: { firstCleanupCount += 1 },
            onDismiss: { firstRestorationCount += 1 }
        ) {
            EmptyView()
        }
        let secondID = host.present(accessibilityLabel: "Second", onDismiss: { secondRestorationCount += 1 }) {
            EmptyView()
        }

        host.presentationDidDisappear(id: firstID)

        #expect(firstCleanupCount == 1)
        #expect(firstRestorationCount == 0)
        #expect(secondRestorationCount == 0)
        #expect(host.presentation?.accessibilityLabel == "Second")

        host.dismiss()
        host.presentationDidDisappear(id: firstID)
        #expect(secondRestorationCount == 0)
        host.presentationDidDisappear(id: secondID)

        #expect(firstRestorationCount == 0)
        #expect(secondRestorationCount == 1)
    }

    @Test func busyConfirmationCannotBeDismissedOrReplacedBeforeSavingSettles() {
        let host = PickyHubModalHost()
        var busy = true
        var cleanups = 0
        let id = host.present(accessibilityLabel: "Saving", canDismiss: { !busy }, onWillDismiss: { cleanups += 1 }) { EmptyView() }
        host.dismiss()
        let replacementID = host.present(accessibilityLabel: "Replacement") { EmptyView() }
        #expect(host.presentationID == id)
        #expect(replacementID == id)
        #expect(cleanups == 0)
        busy = false
        host.dismiss()
        #expect(host.presentationID == nil)
        #expect(cleanups == 1)
    }

    @Test func presentationIDClearsImmediatelyWhenDismissed() {
        let host = PickyHubModalHost()
        let presentationID = host.present(accessibilityLabel: "Confirmation") {
            EmptyView()
        }

        #expect(host.presentationID == presentationID)

        host.dismiss()

        #expect(host.presentationID == nil)
    }

}
