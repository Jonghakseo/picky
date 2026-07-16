//
//  PickyHUDDockOverflowPolicyTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyHUDDockOverflowPolicyTests {
    @Test func keepsRailAtContentLengthWhenItExactlyFits() {
        let layout = PickyHUDDockOverflowPolicy.layout(
            contentLength: 420,
            availableLength: 420,
            fixedChromeLength: 110
        )

        #expect(layout.railLength == 420)
        #expect(layout.sessionsViewportLength == 310)
        #expect(!layout.needsScroll)
    }

    @Test func clampsRailAndFlagsScrollWhenContentExceedsBudgetByOnePoint() {
        let layout = PickyHUDDockOverflowPolicy.layout(
            contentLength: 421,
            availableLength: 420,
            fixedChromeLength: 110
        )

        #expect(layout.railLength == 420)
        #expect(layout.sessionsViewportLength == 310)
        #expect(layout.needsScroll)
    }

    @Test func reservesPersistentChromeForLargeSessionLists() {
        let layout = PickyHUDDockOverflowPolicy.layout(
            contentLength: 5_000,
            availableLength: 600,
            fixedChromeLength: 110
        )

        #expect(layout.railLength == 600)
        #expect(layout.sessionsViewportLength == 490)
        #expect(layout.needsScroll)
    }

    @Test func sanitizesInvalidLengthsWithoutCreatingNegativeViewport() {
        let layout = PickyHUDDockOverflowPolicy.layout(
            contentLength: -1,
            availableLength: -1,
            fixedChromeLength: 110
        )

        #expect(layout.railLength == 0)
        #expect(layout.sessionsViewportLength == 0)
        #expect(!layout.needsScroll)
    }
}
