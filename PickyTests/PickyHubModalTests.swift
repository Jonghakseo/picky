//
//  PickyHubModalTests.swift
//  PickyTests
//

import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHubModalTests {
    @Test func dismissalCompletesOnceWithoutAViewLifecycleCallback() async {
        let host = PickyHubModalHost()
        var restorations = 0
        host.present(accessibilityLabel: "First", onDismiss: { restorations += 1 }) { EmptyView() }
        host.dismiss()
        host.dismiss()

        #expect(host.presentation == nil)
        #expect(restorations == 0, "Focus state must not change inside the dismissing action")
        await waitUntil { restorations == 1 }
        #expect(host.renderedPresentation == nil)
        #expect(restorations == 1)
    }

    @Test func lateDismissalDoesNotRepeatCleanupOrRestoration() async {
        let host = PickyHubModalHost()
        var cleanups = 0
        var restorations = 0
        host.present(
            accessibilityLabel: "Confirmation",
            onWillDismiss: { cleanups += 1 },
            onDismiss: { restorations += 1 },
            content: { EmptyView() }
        )
        host.dismiss()
        #expect(cleanups == 1)
        await waitUntil { restorations == 1 }
        host.dismiss()
        #expect(host.presentationID == nil)
        #expect(cleanups == 1)
        #expect(restorations == 1)
    }

    @Test func replacementCleansUpThePreviousPresentationWithoutRestoringItsFocus() async {
        let host = PickyHubModalHost()
        var firstCleanups = 0
        var firstRestorations = 0
        var secondRestorations = 0
        host.present(
            accessibilityLabel: "First",
            onWillDismiss: { firstCleanups += 1 },
            onDismiss: { firstRestorations += 1 },
            content: { EmptyView() }
        )
        let secondID = host.present(accessibilityLabel: "Second", onDismiss: { secondRestorations += 1 }) { EmptyView() }
        #expect(firstCleanups == 1)
        #expect(host.presentationID == secondID)
        #expect(host.renderedPresentation?.id == secondID)
        host.dismiss()
        await waitUntil { secondRestorations == 1 }
        #expect(firstRestorations == 0)
        #expect(secondRestorations == 1)
    }

    @Test func newPresentationCancelsRestorationQueuedByVisualRemoval() async {
        let host = PickyHubModalHost()
        var firstRestorations = 0
        var secondRestorations = 0
        host.present(accessibilityLabel: "First", onDismiss: { firstRestorations += 1 }) { EmptyView() }
        host.dismiss()
        // This user action follows the queued visual removal but precedes its
        // deferred focus restoration. An old callback must not steal focus.
        DispatchQueue.main.async {
            host.present(accessibilityLabel: "Second", onDismiss: { secondRestorations += 1 }) { EmptyView() }
            host.dismiss()
        }
        await waitUntil { secondRestorations == 1 }
        #expect(firstRestorations == 0)
        #expect(secondRestorations == 1)
    }

    @Test func busyConfirmationCannotBeDismissedOrReplacedBeforeSavingSettles() {
        let host = PickyHubModalHost()
        var busy = true
        var cleanups = 0
        let id = host.present(accessibilityLabel: "Saving", canDismiss: { !busy }, onWillDismiss: { cleanups += 1 }) { EmptyView() }
        host.dismiss()
        let replacementID = host.present(accessibilityLabel: "Replacement") { EmptyView() }
        #expect(host.presentationID == id)
        #expect(host.renderedPresentation?.id == id)
        #expect(replacementID == id)
        #expect(cleanups == 0)
        busy = false
        host.dismiss()
        #expect(host.presentationID == nil)
        #expect(cleanups == 1)
    }

    @Test func presentationIDClearsImmediatelyWhenDismissed() {
        let host = PickyHubModalHost()
        let id = host.present(accessibilityLabel: "Confirmation") { EmptyView() }
        #expect(host.presentationID == id)
        host.dismiss()
        #expect(host.presentationID == nil)
    }

    @Test func guardedDismissalOnlyClosesThePresentationThatStartedTheWork() {
        let host = PickyHubModalHost()
        let firstID = host.present(accessibilityLabel: "Feedback") { EmptyView() }
        let secondID = host.present(accessibilityLabel: "Replacement") { EmptyView() }

        host.dismiss(ifPresenting: firstID)
        #expect(host.presentationID == secondID)

        host.dismiss(ifPresenting: secondID)
        #expect(host.presentationID == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
