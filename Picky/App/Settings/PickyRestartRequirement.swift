//
//  PickyRestartRequirement.swift
//  Picky
//
//  Small policy object for deciding when a Settings edit needs a full Picky
//  relaunch instead of a live settings sync. Keep this list intentionally
//  narrow: only settings captured by the running process / primary daemon at
//  launch belong here.
//

import Foundation

struct PickyAppliedRestartSettingsSnapshot: Equatable {
    var mainAgentRuntimeMode: PickyMainAgentRuntimeMode
    var piCodingAgentDirPath: String
}

struct PickyRestartRequirement: Equatable {
    enum Reason: Equatable {
        case mainAgentRuntime(desired: PickyMainAgentRuntimeMode, applied: PickyMainAgentRuntimeMode)
        case piCodingAgentDir(desiredPath: String, appliedPath: String)
    }

    var reasons: [Reason]

    var isRequired: Bool { !reasons.isEmpty }

    static let none = PickyRestartRequirement(reasons: [])
}

enum PickyRestartRequirementDetector {
    static func snapshot(
        from settings: PickySettings,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        runtimeMode: PickyMainAgentRuntimeMode = AppBundleConfiguration.effectiveRuntimeMode
    ) -> PickyAppliedRestartSettingsSnapshot {
        let normalized = settings.normalizedPaths()
        let resolved = PickyPiInstallation.resolve(
            preferences: PickyPiInstallation.preferences(from: normalized),
            homeURL: homeURL,
            environment: environment,
            fileManager: fileManager
        )
        return PickyAppliedRestartSettingsSnapshot(
            mainAgentRuntimeMode: runtimeMode,
            piCodingAgentDirPath: standardizedPath(resolved.codingAgentDirURL.path)
        )
    }

    static func requirement(
        for settings: PickySettings,
        applied snapshot: PickyAppliedRestartSettingsSnapshot,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> PickyRestartRequirement {
        let desired = self.snapshot(
            from: settings,
            environment: environment,
            homeURL: homeURL,
            fileManager: fileManager,
            runtimeMode: settings.mainAgentRuntimeMode
        )
        var reasons: [PickyRestartRequirement.Reason] = []

        if desired.mainAgentRuntimeMode != snapshot.mainAgentRuntimeMode {
            reasons.append(.mainAgentRuntime(
                desired: desired.mainAgentRuntimeMode,
                applied: snapshot.mainAgentRuntimeMode
            ))
        }

        if desired.piCodingAgentDirPath != snapshot.piCodingAgentDirPath {
            reasons.append(.piCodingAgentDir(
                desiredPath: desired.piCodingAgentDirPath,
                appliedPath: snapshot.piCodingAgentDirPath
            ))
        }

        return PickyRestartRequirement(reasons: reasons)
    }

    private static func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

@MainActor
enum PickyRestartSettingsSnapshotStore {
    private static var appliedSnapshot: PickyAppliedRestartSettingsSnapshot?

    static func captureIfNeeded(settings: PickySettings) {
        guard appliedSnapshot == nil else { return }
        appliedSnapshot = PickyRestartRequirementDetector.snapshot(from: settings)
    }

    static func requirement(for settings: PickySettings) -> PickyRestartRequirement {
        let snapshot = appliedSnapshot ?? PickyRestartRequirementDetector.snapshot(from: settings)
        return PickyRestartRequirementDetector.requirement(for: settings, applied: snapshot)
    }

    static func resetForTesting() {
        appliedSnapshot = nil
    }
}
