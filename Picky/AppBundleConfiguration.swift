//
//  AppBundleConfiguration.swift
//  Picky
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    static func stringValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    @TaskLocal
    static var testRealtimeOptInOverride: Bool?

    static var realtimeOptIn: Bool {
        if let override = testRealtimeOptInOverride { return override }
        guard let buildInfoPath = Bundle.main.path(forResource: "PickyBuildInfo", ofType: "json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: buildInfoPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let raw = json["realtimeOptIn"] as? String ?? ""
        return raw == "1" || raw.lowercased() == "true"
    }

    /// Tests inject a runtime mode here so the opt-in=1 guards inside
    /// CompanionManager / PickyApp can be exercised without rebuilding
    /// `PickyBuildInfo.json`. Production code never sets this; the runtime
    /// flow falls back to the bundled build constant when this is `nil`.
    ///
    /// Declared as `@TaskLocal` rather than a plain `static var` so parallel
    /// swift-testing suites can't smash each other's overrides. Each test
    /// reads/writes through `withValue`, which scopes the override to the
    /// current task tree without affecting siblings.
    @TaskLocal
    static var testRuntimeModeOverride: PickyMainAgentRuntimeMode?

    /// Tests can scope runtime-mode snapshot reads to a temporary settings file.
    @TaskLocal
    static var testRuntimeModeSettingsURL: URL?

    nonisolated(unsafe) private static let runtimeModeCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedLaunchRuntimeModes: [URL: PickyMainAgentRuntimeMode] = [:]

    /// Production resolves this once from persisted Settings at process launch
    /// so users can choose Pi or OpenAI Realtime and have the selection take
    /// effect on the next app launch. Later Settings edits update the desired
    /// value on disk, but the running app keeps this launch snapshot to avoid
    /// mixing UI/voice/daemon runtime assumptions in one process.
    ///
    /// `PICKY_REALTIME_OPT_IN=1` is now only a compatibility seed: on first
    /// load, `PickySettingsStore` migrates unmarked settings to
    /// `.openAIRealtime` so existing realtime-channel users do not fall back to
    /// Pi after updating.
    static var effectiveRuntimeMode: PickyMainAgentRuntimeMode {
        if let override = testRuntimeModeOverride { return override }

        let store: PickySettingsStore
        if let settingsURL = testRuntimeModeSettingsURL {
            store = PickySettingsStore(url: settingsURL)
        } else {
            store = PickySettingsStore()
        }
        let cacheKey = store.url

        runtimeModeCacheLock.lock()
        defer { runtimeModeCacheLock.unlock() }

        if let cachedLaunchRuntimeMode = cachedLaunchRuntimeModes[cacheKey] {
            return cachedLaunchRuntimeMode
        }

        let mode = store.load().mainAgentRuntimeMode
        cachedLaunchRuntimeModes[cacheKey] = mode
        return mode
    }

    static func resetEffectiveRuntimeModeCacheForTesting() {
        runtimeModeCacheLock.lock()
        defer { runtimeModeCacheLock.unlock() }
        let store: PickySettingsStore
        if let settingsURL = testRuntimeModeSettingsURL {
            store = PickySettingsStore(url: settingsURL)
        } else {
            store = PickySettingsStore()
        }
        cachedLaunchRuntimeModes[store.url] = nil
    }

    /// Historical name retained for call-site compatibility. This now means
    /// "the runtime applied for the current launch is OpenAI Realtime", not a
    /// hard build flavour where Pi is unavailable.
    static var isRealtimeOnlyBuild: Bool {
        effectiveRuntimeMode == .openAIRealtime
    }

    /// Release channel from `PickyBuildInfo.json` (`stable` / `beta` / `alpha`).
    /// Local dev builds without the bundled JSON file fall back to `alpha`,
    /// which intentionally disables Sparkle updates so unsigned local runs do
    /// not try to swap themselves with a notarized GitHub Release.
    static var releaseChannel: String {
        guard let buildInfoPath = Bundle.main.path(forResource: "PickyBuildInfo", ofType: "json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: buildInfoPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["releaseChannel"] as? String else {
            return "alpha"
        }
        return value.lowercased()
    }

    /// Build label from `PickyBuildInfo.json` (e.g. `beta.123-abc1234-...`).
    /// `nil` when the bundled JSON file is absent (Xcode IDE dev builds).
    static var buildLabel: String? {
        guard let buildInfoPath = Bundle.main.path(forResource: "PickyBuildInfo", ofType: "json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: buildInfoPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["buildLabel"] as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
