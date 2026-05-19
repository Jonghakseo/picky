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

    static var realtimeOptIn: Bool {
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

    /// The runtime mode the daemon should always be driven to in this build.
    ///
    /// `PICKY_REALTIME_OPT_IN=1` flips Picky into a Realtime-only product:
    /// the user can no longer pick the Pi runtime from Settings, and every
    /// daemon command, voice turn, and assistant reply is expected to go
    /// through OpenAI Realtime. The legacy `PICKY_REALTIME_OPT_IN=0` builds
    /// keep their existing behaviour and always resolve to `.pi`. Using a
    /// single helper here means we never need to keep five call sites in
    /// sync with the `realtimeOptIn` build flag.
    ///
    /// Note: `PickySettings.mainAgentRuntimeMode` is intentionally still
    /// honoured on opt-in=0 (it's hard-pinned to `.pi` there) and ignored
    /// on opt-in=1 (forced to `.openAIRealtime`). The stored field stays in
    /// the JSON for forward/backward compatibility across the two build
    /// flavours.
    static var effectiveRuntimeMode: PickyMainAgentRuntimeMode {
        if let override = testRuntimeModeOverride { return override }
        return realtimeOptIn ? .openAIRealtime : .pi
    }

    /// Convenience: `true` when this build wires Picky exclusively through
    /// OpenAI Realtime. Use this to gate Settings UI, provider factories,
    /// onboarding gates, and tests that should only run on the realtime
    /// build flavour.
    static var isRealtimeOnlyBuild: Bool {
        if let override = testRuntimeModeOverride { return override == .openAIRealtime }
        return realtimeOptIn
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
