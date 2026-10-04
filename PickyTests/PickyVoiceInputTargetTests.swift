//
//  PickyVoiceInputTargetTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyVoiceInputTargetTests {
    @Test func armedTargetSnapshotsDispatchSemantics() {
        let inputID = UUID()
        let snapshot = PickyVoiceInputTargetPolicy.resolve(
            inputID: inputID,
            armedTarget: PickyScreenContextTargetSnapshot(
                sessionID: "pickle-armed",
                sticky: true,
                revision: 42
            ),
            armedDispatchMode: .steer
        )

        #expect(snapshot == PickyVoiceInputTargetSnapshot(
            inputID: inputID,
            target: .pickle(
                sessionID: "pickle-armed",
                origin: .armed(dispatchMode: .steer, sticky: true, revision: 42)
            )
        ))
    }

    /// Global Push to Talk no longer targets the Pickle under the pointer:
    /// without an armed target it always goes to the main agent.
    @Test func missingArmedTargetRoutesToMain() {
        let snapshot = PickyVoiceInputTargetPolicy.resolve(
            inputID: UUID(),
            armedTarget: nil,
            armedDispatchMode: .followUp
        )

        #expect(snapshot.target == .main)
    }
}
