//
//  PickyPiInstallation.swift
//  Picky
//
//  Resolves the user's Pi CLI and Pi coding-agent directory. Picky defaults to
//  auto-discovery so non-standard Pi installs do not need goofy symlinks, while
//  still preserving ~/.pi/agent compatibility for existing users.
//

import Foundation

struct PickyPiInstallationPreferences: Equatable {
    var binaryPath: String = ""
    var codingAgentDir: String = ""
}

struct PickyResolvedPiInstallation: Equatable {
    var binaryURL: URL?
    var codingAgentDirURL: URL
}

enum PickyPiInstallation {
    static let environmentAgentDirKey = "PI_CODING_AGENT_DIR"

    static func preferences(from settings: PickySettings) -> PickyPiInstallationPreferences {
        PickyPiInstallationPreferences(
            binaryPath: settings.piBinaryPath,
            codingAgentDir: settings.piCodingAgentDir
        )
    }

    static func defaultAgentDir(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeURL.appendingPathComponent(".pi/agent", isDirectory: true)
    }

    static func resolve(
        preferences: PickyPiInstallationPreferences = .init(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> PickyResolvedPiInstallation {
        let expandedBinary = normalizedPath(preferences.binaryPath)
        let expandedConfiguredAgentDir = normalizedPath(preferences.codingAgentDir)
        let expandedEnvironmentAgentDir = normalizedPath(environment[environmentAgentDirKey] ?? "")

        let configuredAgentDirURL = expandedConfiguredAgentDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let environmentAgentDirURL = expandedEnvironmentAgentDir.map { URL(fileURLWithPath: $0, isDirectory: true) }

        let binaryURL: URL?
        if let expandedBinary {
            binaryURL = URL(fileURLWithPath: expandedBinary, isDirectory: false)
        } else if let candidate = configuredAgentDirURL?.appendingPathComponent("bin/pi", isDirectory: false), fileManager.isExecutableFile(atPath: candidate.path) {
            binaryURL = candidate
        } else if let candidate = environmentAgentDirURL?.appendingPathComponent("bin/pi", isDirectory: false), fileManager.isExecutableFile(atPath: candidate.path) {
            binaryURL = candidate
        } else {
            binaryURL = findExecutable(named: "pi", homeURL: homeURL, environment: environment, fileManager: fileManager)
                ?? legacyPiBinaryURL(homeURL: homeURL, fileManager: fileManager)
        }

        let codingAgentDirURL = configuredAgentDirURL
            ?? environmentAgentDirURL
            ?? inferredAgentDir(fromBinaryURL: binaryURL)
            ?? defaultAgentDir(homeURL: homeURL)

        return PickyResolvedPiInstallation(binaryURL: binaryURL, codingAgentDirURL: codingAgentDirURL)
    }

    static func mergedEnvironment(
        preferences: PickyPiInstallationPreferences = .init(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String: String] {
        let resolved = resolve(
            preferences: preferences,
            homeURL: homeURL,
            environment: environment,
            fileManager: fileManager
        )
        var merged = environment
        merged["PATH"] = augmentedPATH(homeURL: homeURL, agentDirURL: resolved.codingAgentDirURL, environment: environment)
        merged[environmentAgentDirKey] = resolved.codingAgentDirURL.path
        return merged
    }

    static func settingsURL(
        preferences: PickyPiInstallationPreferences = .init(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        resolve(
            preferences: preferences,
            homeURL: homeURL,
            environment: environment,
            fileManager: fileManager
        )
        .codingAgentDirURL
        .appendingPathComponent("settings.json", isDirectory: false)
    }

    private static func legacyPiBinaryURL(homeURL: URL, fileManager: FileManager) -> URL? {
        let preferredPi = defaultAgentDir(homeURL: homeURL).appendingPathComponent("bin/pi", isDirectory: false)
        return fileManager.isExecutableFile(atPath: preferredPi.path) ? preferredPi : nil
    }

    private static func findExecutable(
        named name: String,
        homeURL: URL,
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        for directory in searchPathDirectories(homeURL: homeURL, environment: environment) {
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func searchPathDirectories(homeURL: URL, environment: [String: String]) -> [URL] {
        var paths: [String] = []
        if let path = environment["PATH"], !path.isEmpty {
            paths.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        paths.append(contentsOf: [
            defaultAgentDir(homeURL: homeURL).appendingPathComponent("bin", isDirectory: true).path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ])

        var seen = Set<String>()
        return paths.compactMap { rawPath in
            let expanded = NSString(string: rawPath).expandingTildeInPath
            let standardized = (expanded as NSString).standardizingPath
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { return nil }
            return URL(fileURLWithPath: standardized, isDirectory: true)
        }
    }

    private static func augmentedPATH(homeURL: URL, agentDirURL: URL, environment: [String: String]) -> String {
        var paths = searchPathDirectories(homeURL: homeURL, environment: environment).map(\.path)
        paths.insert(agentDirURL.appendingPathComponent("bin", isDirectory: true).path, at: 0)
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func inferredAgentDir(fromBinaryURL binaryURL: URL?) -> URL? {
        guard let binaryURL, binaryURL.lastPathComponent == "pi" else { return nil }
        let binURL = binaryURL.deletingLastPathComponent()
        guard binURL.lastPathComponent == "bin" else { return nil }
        return binURL.deletingLastPathComponent()
    }

    static func normalizedPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (NSString(string: trimmed).expandingTildeInPath as NSString).standardizingPath
    }
}
