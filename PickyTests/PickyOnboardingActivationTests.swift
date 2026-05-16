//
//  PickyOnboardingActivationTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyOnboardingActivationTests {
    @Test func shouldShowOnboardingIsTrueOnFreshInstallAndFalseAfterCompletion() throws {
        let context = try makeContext()
        let activator = PickyOnboardingActivator(settingsStore: context.store)

        // Fresh install: defaults() seeds version 0, which is behind the build's expectation.
        #expect(activator.shouldShowOnboarding == true)

        activator.markOnboardingComplete()
        #expect(activator.shouldShowOnboarding == false)
        #expect(context.store.load().onboardingCompletedVersion == PickyOnboardingVersion.current)
    }

    @Test func resetOnboardingForReplayPutsTheUserBackInTheEligiblePool() throws {
        let context = try makeContext()
        let activator = PickyOnboardingActivator(settingsStore: context.store)
        activator.markOnboardingComplete()
        #expect(activator.shouldShowOnboarding == false)

        activator.resetOnboardingForReplay()

        #expect(activator.shouldShowOnboarding == true)
        #expect(context.store.load().onboardingCompletedVersion == 0)
    }

    @Test func markCompleteWritesThroughEvenWhenCalledTwice() throws {
        // Idempotency matters because the overlay may flush its completion call
        // on both a successful finish and on dismissal. Two writes should not
        // surface visible state changes after the first.
        let context = try makeContext()
        let activator = PickyOnboardingActivator(settingsStore: context.store)

        activator.markOnboardingComplete()
        let snapshot = context.store.load().onboardingCompletedVersion
        activator.markOnboardingComplete()

        #expect(context.store.load().onboardingCompletedVersion == snapshot)
        #expect(snapshot == PickyOnboardingVersion.current)
    }

    private struct Context {
        let root: URL
        let store: PickySettingsStore
    }

    private func makeContext() throws -> Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-onboarding-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = PickySettingsStore(appSupportRoot: root)
        var seed = PickySettings.defaults(appSupportRoot: root)
        seed.defaultCwd = project.path
        seed.worktreeParent = project.path
        try store.save(seed)
        // Replace the freshly-saved settings with a fresh-install baseline: zero out the
        // onboarding version so `shouldShowOnboarding` evaluates against the same state
        // an actual first launch would see.
        seed.onboardingCompletedVersion = 0
        try store.save(seed)
        return Context(root: root, store: store)
    }
}
