//
//  CompanionPanelFooterPresentationTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct CompanionPanelFooterPresentationTests {
    @Test func visibleDockOffersHideAction() {
        let presentation = CompanionPanelDockActionPresentation.resolve(isDockVisible: true)

        #expect(presentation.titleKey == "footer.dock.hide")
        #expect(presentation.systemImage == "dock.rectangle")
    }

    @Test func hiddenDockOffersShowAction() {
        let presentation = CompanionPanelDockActionPresentation.resolve(isDockVisible: false)

        #expect(presentation.titleKey == "footer.dock.show")
        #expect(presentation.systemImage == "dock.arrow.up.rectangle")
    }
}
