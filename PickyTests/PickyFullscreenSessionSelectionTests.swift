//
//  PickyFullscreenSessionSelectionTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenSessionSelection")
struct PickyFullscreenSessionSelectionTests {
    @Test func requestedSessionWinsWhenItExists() {
        let candidates = makeCandidates(["stored", "requested", "global"])

        let selected = PickyFullscreenSessionSelection.resolvedSessionID(
            requestedSessionID: "requested",
            storedSelectedSessionID: "stored",
            viewModelSelectedSessionID: "global",
            candidates: candidates
        )

        #expect(selected == "requested")
    }

    @Test func missingRequestedFallsBackToStoredSelection() {
        let candidates = makeCandidates(["stored", "global"])

        let selected = PickyFullscreenSessionSelection.resolvedSessionID(
            requestedSessionID: "missing",
            storedSelectedSessionID: "stored",
            viewModelSelectedSessionID: "global",
            candidates: candidates
        )

        #expect(selected == "stored")
    }

    @Test func missingStoredFallsBackToViewModelSelection() {
        let candidates = makeCandidates(["global", "latest"])

        let selected = PickyFullscreenSessionSelection.resolvedSessionID(
            requestedSessionID: nil,
            storedSelectedSessionID: "missing",
            viewModelSelectedSessionID: "global",
            candidates: candidates
        )

        #expect(selected == "global")
    }

    @Test func fallsBackToMostRecentlyUpdatedCandidate() {
        let base = Date(timeIntervalSince1970: 1_000)
        let candidates = [
            PickyFullscreenSessionSelection.Candidate(id: "old", updatedAt: base),
            PickyFullscreenSessionSelection.Candidate(id: "latest", updatedAt: base.addingTimeInterval(60)),
            PickyFullscreenSessionSelection.Candidate(id: "middle", updatedAt: base.addingTimeInterval(30))
        ]

        let selected = PickyFullscreenSessionSelection.resolvedSessionID(
            requestedSessionID: "missing-requested",
            storedSelectedSessionID: "missing-stored",
            viewModelSelectedSessionID: "missing-global",
            candidates: candidates
        )

        #expect(selected == "latest")
    }

    @Test func returnsNilWithoutCandidates() {
        let selected = PickyFullscreenSessionSelection.resolvedSessionID(
            requestedSessionID: "requested",
            storedSelectedSessionID: "stored",
            viewModelSelectedSessionID: "global",
            candidates: []
        )

        #expect(selected == nil)
    }

    @Test func ignoresEmptyAndWhitespaceIDs() {
        let candidates = makeCandidates(["latest"])

        let selected = PickyFullscreenSessionSelection.resolvedSessionID(
            requestedSessionID: " ",
            storedSelectedSessionID: "",
            viewModelSelectedSessionID: nil,
            candidates: candidates
        )

        #expect(selected == "latest")
    }

    private func makeCandidates(_ ids: [String]) -> [PickyFullscreenSessionSelection.Candidate] {
        let base = Date(timeIntervalSince1970: 1_000)
        return ids.enumerated().map { index, id in
            PickyFullscreenSessionSelection.Candidate(
                id: id,
                updatedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
    }
}
