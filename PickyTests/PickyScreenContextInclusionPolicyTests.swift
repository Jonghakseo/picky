//
//  PickyScreenContextInclusionPolicyTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyScreenContextInclusionPolicyTests {
    // MARK: - Capture candidacy (which displays get captured)

    @Test func allScreensScope_capturesEveryDisplay() {
        for isFocused in [true, false] {
            for hasInk in [true, false] {
                #expect(PickyScreenContextInclusionPolicy.isCaptureCandidate(
                    scope: .allScreens, isFocused: isFocused, hasInk: hasInk
                ))
            }
        }
    }

    @Test func focusedScope_capturesFocusedOrInkedDisplays() {
        #expect(PickyScreenContextInclusionPolicy.isCaptureCandidate(
            scope: .focusedScreen, isFocused: true, hasInk: false
        ))
        // Req 1: drawing on a non-focused monitor pulls it into capture.
        #expect(PickyScreenContextInclusionPolicy.isCaptureCandidate(
            scope: .focusedScreen, isFocused: false, hasInk: true
        ))
        #expect(!PickyScreenContextInclusionPolicy.isCaptureCandidate(
            scope: .focusedScreen, isFocused: false, hasInk: false
        ))
    }

    // MARK: - Ink-only attachment gate

    @Test func inkGateOff_keepsEveryCandidate() {
        #expect(PickyScreenContextInclusionPolicy.passesInkAttachmentGate(onlyWhenInked: false, hasInk: false))
        #expect(PickyScreenContextInclusionPolicy.passesInkAttachmentGate(onlyWhenInked: false, hasInk: true))
    }

    @Test func inkGateOn_keepsOnlyInked() {
        #expect(PickyScreenContextInclusionPolicy.passesInkAttachmentGate(onlyWhenInked: true, hasInk: true))
        #expect(!PickyScreenContextInclusionPolicy.passesInkAttachmentGate(onlyWhenInked: true, hasInk: false))
    }

    // MARK: - Composed "is sent as context" (drives the border)

    @Test func focusedScope_sendsFocusedScreen_whenInkGateOff() {
        #expect(PickyScreenContextInclusionPolicy.isSentAsContext(
            scope: .focusedScreen, onlyWhenInked: false, isFocused: true, hasInk: false
        ))
    }

    @Test func focusedScope_sendsInkedSecondaryScreen_whenInkGateOff() {
        #expect(PickyScreenContextInclusionPolicy.isSentAsContext(
            scope: .focusedScreen, onlyWhenInked: false, isFocused: false, hasInk: true
        ))
    }

    @Test func focusedScope_doesNotSendUntouchedSecondaryScreen() {
        #expect(!PickyScreenContextInclusionPolicy.isSentAsContext(
            scope: .focusedScreen, onlyWhenInked: false, isFocused: false, hasInk: false
        ))
    }

    @Test func onlyWhenInked_sendsOnlyTheDrawnScreen_regardlessOfScope() {
        for scope in PickyScreenContextScope.allCases {
            // Focused-but-not-drawn is withheld until the user draws.
            #expect(!PickyScreenContextInclusionPolicy.isSentAsContext(
                scope: scope, onlyWhenInked: true, isFocused: true, hasInk: false
            ))
            // Drawing on any screen sends exactly that screen.
            #expect(PickyScreenContextInclusionPolicy.isSentAsContext(
                scope: scope, onlyWhenInked: true, isFocused: false, hasInk: true
            ))
        }
    }

    @Test func includedOverrideBypassesScopeAndInkGate() {
        #expect(PickyScreenContextInclusionPolicy.isSentAsContext(
            scope: .focusedScreen,
            onlyWhenInked: true,
            isFocused: false,
            hasInk: false,
            displayOverride: .included
        ))
    }

    @Test func excludedOverrideWinsOverAutomaticInclusion() {
        #expect(!PickyScreenContextInclusionPolicy.isSentAsContext(
            scope: .allScreens,
            onlyWhenInked: false,
            isFocused: true,
            hasInk: true,
            displayOverride: .excluded
        ))
    }

    @Test func nilOverrideRestoresAutomaticPolicy() {
        #expect(PickyScreenContextInclusionPolicy.isSentAsContext(
            scope: .focusedScreen,
            onlyWhenInked: false,
            isFocused: true,
            hasInk: false,
            displayOverride: nil
        ))
        #expect(!PickyScreenContextInclusionPolicy.isSentAsContext(
            scope: .focusedScreen,
            onlyWhenInked: false,
            isFocused: false,
            hasInk: false,
            displayOverride: nil
        ))
    }

    @Test func displaySelectionSnapshotFreezesEffectiveIDsBeforeTopologyChanges() {
        let snapshot = PickyScreenContextDisplaySelectionSnapshot.capture(
            scope: .focusedScreen,
            onlyWhenInked: false,
            displays: [
                .init(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                .init(id: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100))
            ],
            pointerLocation: CGPoint(x: 20, y: 20),
            focusedDisplayID: nil,
            inkGlobalPoints: [CGPoint(x: 120, y: 20)],
            displayOverrides: [1: .excluded]
        )

        #expect(snapshot.includedDisplayIDs == [2])
        // A display connected after submission has no identity in this turn's
        // closed set, so asynchronous enumeration cannot include it.
        #expect(!snapshot.includedDisplayIDs.contains(3))
    }
}
