//
//  PickyOnboardingActivation.swift
//  Picky
//
//  Tiny scaffolding for the interactive onboarding flow. Owns the version
//  constant the rest of the codebase reads to decide whether the takeover
//  overlay should appear on launch, and exposes a small façade so app/Settings
//  code does not poke `PickySettings` directly.
//
//  The actual overlay/scenario/stub-client wiring lands in later phases; this
//  file intentionally stays small and side-effect free so it can be merged on
//  its own.
//

import Foundation

/// Single source of truth for which onboarding revision the app expects each
/// install to have completed. Bumping this number causes anyone whose stored
/// `onboardingCompletedVersion` is lower to be eligible for the onboarding
/// overlay on next launch.
///
/// Keep this independent from the app/Sparkle version: onboarding rarely needs
/// to retrigger and we don't want every dot-release to interrupt users.
enum PickyOnboardingVersion {
    static let current: Int = 1
}

/// Thin coordinator around the persisted onboarding flag. The activator
/// reads/writes through `PickySettingsStore` so the same JSON file backs every
/// state transition.
@MainActor
final class PickyOnboardingActivator {
    private let settingsStore: PickySettingsStore

    init(settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.settingsStore = settingsStore
    }

    /// True when the persisted completion version is behind the build's
    /// expected version. Phase 4 wires this into app launch so the overlay
    /// only shows up on fresh installs (and on explicit replay).
    var shouldShowOnboarding: Bool {
        settingsStore.load().onboardingCompletedVersion < PickyOnboardingVersion.current
    }

    /// Called by the overlay when the user finishes or skips the demo so the
    /// flow does not retrigger on the next launch.
    func markOnboardingComplete() {
        update { settings in
            settings.onboardingCompletedVersion = PickyOnboardingVersion.current
        }
    }

    /// Resets the persisted version to zero so the overlay reappears the next
    /// time `shouldShowOnboarding` is consulted. Settings exposes this via the
    /// "Replay onboarding" button.
    func resetOnboardingForReplay() {
        update { settings in
            settings.onboardingCompletedVersion = 0
        }
    }

    private func update(_ mutate: (inout PickySettings) -> Void) {
        var settings = settingsStore.load()
        mutate(&settings)
        do {
            try settingsStore.save(settings)
            NotificationCenter.default.post(name: .pickySettingsDidSave, object: nil)
        } catch {
            // Onboarding state is non-critical; if persistence fails the user
            // can always retrigger via Settings. Swallow rather than throw so
            // a transient disk issue doesn't crash the menu bar.
            print("⚠️ Picky onboarding: failed to persist completion flag: \(error)")
        }
    }
}
