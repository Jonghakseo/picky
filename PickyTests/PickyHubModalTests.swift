//
//  PickyHubModalTests.swift
//  PickyTests
//

import Combine
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHubModalTests {
    @Test func dismissalRestoresItsTriggerOnceOutsideTheRemovalUpdate() async {
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

        // SwiftUI invokes the removal callback during a view update. Updating
        // the caller's observed focus state synchronously is not safe there.
        #expect(restorationCount == 0)
        await drainMainQueue()
        #expect(restorationCount == 1)
    }

    @Test func dismissalPublishesOverlayRemovalBeforeItsFocusRestoration() async {
        let host = PickyHubModalHost()
        var restorationCount = 0

        let id = host.present(
            accessibilityLabel: "Confirmation",
            onDismiss: { restorationCount += 1 },
            content: { EmptyView() }
        )
        host.dismiss()

        #expect(host.presentationID == nil)
        #expect(host.renderedPresentation?.id == id)

        await drainMainQueue()
        await drainMainQueue()

        #expect(host.renderedPresentation == nil)
        #expect(restorationCount == 0)

        host.presentationDidDisappear(id: id)
        await drainMainQueue()

        #expect(restorationCount == 1)
    }

    @Test func rendersStoredPresentationWhenItNotifiesSwiftUI() async {
        let host = PickyHubModalHost()
        var renderedIDs = [UUID?]()
        let observation = host.objectWillChange.sink {
            renderedIDs.append(host.renderedPresentation?.id)
        }
        defer { observation.cancel() }

        let id = host.present(accessibilityLabel: "Confirmation") { EmptyView() }
        #expect(renderedIDs == [id])

        host.dismiss()
        await drainMainQueue()
        await drainMainQueue()

        #expect(renderedIDs == [id, nil])
    }

    @Test func lateRemovalAfterCleanupDoesNotRepeatFocusRestoration() async {
        let host = PickyHubModalHost()
        var cleanupCount = 0
        var restorationCount = 0
        let id = host.present(
            accessibilityLabel: "Confirmation",
            onWillDismiss: { cleanupCount += 1 },
            onDismiss: { restorationCount += 1 },
            content: { EmptyView() }
        )
        host.dismiss()
        host.presentationDidDisappear(id: id)

        // Drain a later cleanup callback before asserting the final count.
        let lateRemoval = Task { @MainActor in
            host.dismiss()
            host.presentationDidDisappear(id: id)
        }
        await lateRemoval.value
        await drainMainQueue()

        #expect(host.presentationID == nil)
        #expect(cleanupCount == 1)
        #expect(restorationCount == 1)
    }

    @Test func replacementCleansUpTheDismissedPresentationWithoutRestoringItsFocus() async {
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
        await drainMainQueue()

        #expect(firstRestorationCount == 0)
        #expect(secondRestorationCount == 1)
    }

    @Test func newPresentationCancelsRestorationAlreadyQueuedByRemoval() async {
        let host = PickyHubModalHost()
        var firstRestorations = 0
        var secondRestorations = 0
        let firstID = host.present(accessibilityLabel: "First", onDismiss: { firstRestorations += 1 }) { EmptyView() }
        host.dismiss()
        host.presentationDidDisappear(id: firstID)

        let secondID = host.present(accessibilityLabel: "Second", onDismiss: { secondRestorations += 1 }) { EmptyView() }
        await drainMainQueue()
        #expect(host.presentationID == secondID)
        #expect(firstRestorations == 0)
        #expect(secondRestorations == 0)

        host.dismiss()
        host.presentationDidDisappear(id: secondID)
        await drainMainQueue()
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

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
