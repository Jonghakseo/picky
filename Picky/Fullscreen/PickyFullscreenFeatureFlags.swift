//
//  PickyFullscreenFeatureFlags.swift
//  Picky
//
//  Runtime feature gate for fullscreen workspace entry points. The fullscreen
//  workspace UI is still being polished, so the dock entry control is hidden
//  unless `PICKY_FULLSCREEN_ENABLED=1` is set in the launching environment.
//  `scripts/run-dev-signed-app.sh` injects this variable via `open --env`.
//

import Foundation

enum PickyFullscreenFeatureFlags {
    static let envVarName = "PICKY_FULLSCREEN_ENABLED"

    static let isEnabled: Bool = evaluate(env: ProcessInfo.processInfo.environment)

    static func evaluate(env: [String: String]) -> Bool {
        guard let raw = env[envVarName]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
