//
//  PickyVoiceInputTargetTests.swift
//  PickyTests
//

import AppKit
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyVoiceInputTargetTests {
    @Test func armedTargetWinsOverPointerAndSnapshotsDispatchSemantics() {
        let inputID = UUID()
        let snapshot = PickyVoiceInputTargetPolicy.resolve(
            inputID: inputID,
            armedTarget: PickyScreenContextTargetSnapshot(
                sessionID: "pickle-armed",
                sticky: true,
                revision: 42
            ),
            pointerSessionID: "pickle-pointer",
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

    @Test func pointerTargetBecomesFollowUpOriginWhenNothingIsArmed() {
        let inputID = UUID()
        let snapshot = PickyVoiceInputTargetPolicy.resolve(
            inputID: inputID,
            armedTarget: nil,
            pointerSessionID: " pickle-pointer ",
            armedDispatchMode: .steer
        )

        #expect(snapshot.target == .pickle(sessionID: "pickle-pointer", origin: .pointer))
    }

    @Test func missingArmedAndPointerTargetsRoutesToMain() {
        let snapshot = PickyVoiceInputTargetPolicy.resolve(
            inputID: UUID(),
            armedTarget: nil,
            pointerSessionID: nil,
            armedDispatchMode: .followUp
        )

        #expect(snapshot.target == .main)
    }

    @Test func hitTestPolicyUsesFrontmostContainingCardAcrossScreenCoordinates() {
        let candidates = [
            PickyVoiceTargetHitCandidate(
                sessionID: "pickle-back",
                screenFrame: CGRect(x: -900, y: 100, width: 600, height: 500),
                windowOrder: 2
            ),
            PickyVoiceTargetHitCandidate(
                sessionID: "pickle-front",
                screenFrame: CGRect(x: -800, y: 200, width: 600, height: 500),
                windowOrder: 0
            )
        ]

        #expect(PickyVoiceTargetHitTestPolicy.sessionID(
            at: CGPoint(x: -700, y: 300),
            candidates: candidates
        ) == "pickle-front")
        #expect(PickyVoiceTargetHitTestPolicy.sessionID(
            at: CGPoint(x: 100, y: 100),
            candidates: candidates
        ) == nil)
    }

    @Test func registryDropsUnregisteredAndUnavailableRegions() {
        let registry = PickyVoiceTargetHitTestRegistry(frontmostWindowNumberProvider: { _ in 0 })
        let available = FakeVoiceTargetHitRegion(candidate: PickyVoiceTargetHitCandidate(
            sessionID: "pickle-available",
            screenFrame: CGRect(x: 10, y: 20, width: 100, height: 80),
            windowOrder: 0
        ))
        let unavailable = FakeVoiceTargetHitRegion(candidate: nil)
        registry.register(available)
        registry.register(unavailable)

        #expect(registry.sessionID(at: CGPoint(x: 30, y: 40)) == "pickle-available")
        registry.unregister(available)
        #expect(registry.sessionID(at: CGPoint(x: 30, y: 40)) == nil)
    }

    @Test func registryRejectsCardWhenAnotherWindowIsFrontmostAtPoint() {
        let registry = PickyVoiceTargetHitTestRegistry(frontmostWindowNumberProvider: { _ in 99 })
        let coveredCard = FakeVoiceTargetHitRegion(candidate: PickyVoiceTargetHitCandidate(
            sessionID: "pickle-covered",
            screenFrame: CGRect(x: 10, y: 20, width: 100, height: 80),
            windowOrder: 0,
            windowNumber: 42
        ))
        registry.register(coveredCard)

        #expect(registry.sessionID(at: CGPoint(x: 30, y: 40)) == nil)
    }

    @Test func screenContextRevisionChangesOnlyWhenRoutingSemanticsChange() throws {
        let suiteName = "PickyVoiceInputTargetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PickyUserDefaultsSessionSelectionStore(defaults: defaults)

        store.setScreenContextTarget(sessionID: "pickle-a", sticky: false, label: "A")
        let armedRevision = store.screenContextTargetRevision
        #expect(armedRevision > 0)

        store.setScreenContextTarget(sessionID: "pickle-a", sticky: false, label: "Renamed A")
        #expect(store.screenContextTargetRevision == armedRevision)

        store.setScreenContextTarget(sessionID: "pickle-a", sticky: true, label: "Renamed A")
        #expect(store.screenContextTargetRevision > armedRevision)
    }

    @Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))
    func appKitRegionExcludesOrderedOutHiddenAndIneligibleCards() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let region = PickyVoiceTargetHitRegionNSView(frame: NSRect(x: 20, y: 30, width: 120, height: 80))
        region.sessionID = "pickle-visible"
        region.isVoiceTargetEligible = true
        root.addSubview(region)
        window.contentView = root
        window.orderFrontRegardless()
        let registry = PickyVoiceTargetHitTestRegistry(
            frontmostWindowNumberProvider: { _ in window.windowNumber }
        )
        registry.register(region)

        let candidate = try #require(region.voiceTargetHitCandidate)
        #expect(candidate.sessionID == "pickle-visible")
        #expect(registry.sessionID(at: CGPoint(
            x: candidate.screenFrame.midX,
            y: candidate.screenFrame.midY
        )) == "pickle-visible")

        root.isHidden = true
        #expect(region.voiceTargetHitCandidate == nil)
        root.isHidden = false

        root.alphaValue = 0
        #expect(region.voiceTargetHitCandidate == nil)
        root.alphaValue = 1

        region.isVoiceTargetEligible = false
        #expect(region.voiceTargetHitCandidate == nil)
        region.isVoiceTargetEligible = true

        window.orderOut(nil)
        #expect(region.voiceTargetHitCandidate == nil)
    }
}

@MainActor
private final class FakeVoiceTargetHitRegion: PickyVoiceTargetHitRegionProviding {
    var candidate: PickyVoiceTargetHitCandidate?

    init(candidate: PickyVoiceTargetHitCandidate?) {
        self.candidate = candidate
    }

    var voiceTargetHitCandidate: PickyVoiceTargetHitCandidate? { candidate }
}
