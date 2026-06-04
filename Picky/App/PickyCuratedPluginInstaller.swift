//
//  PickyCuratedPluginInstaller.swift
//  Picky
//
//  Installs curated third-party Pi packages through the Pi CLI. Unlike bundled
//  extensions, curated packages are tracked by Pi's package settings and should
//  be installed/removed through `pi install` / `pi remove` so Pi owns download,
//  manifest resolution, and package directory layout.
//

import Foundation

enum PickyCuratedPluginInstaller {
    struct CommandResult: Equatable {
        let exitCode: Int32
        let output: String
    }

    enum Status: Equatable {
        case notInstalled
        case installed
    }

    enum CommandError: LocalizedError, Equatable {
        case piMissing
        case failed(command: String, exitCode: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .piMissing:
                return "Pi CLI was not found. Set the Pi binary path in Settings or make `pi` discoverable on PATH."
            case .failed(let command, let exitCode, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "`pi \(command)` failed with exit code \(exitCode)."
                }
                return "`pi \(command)` failed with exit code \(exitCode): \(detail)"
            }
        }
    }

    typealias CommandRunner = (_ arguments: [String], _ homeURL: URL, _ fileManager: FileManager, _ preferences: PickyPiInstallationPreferences) throws -> CommandResult

    static func status(
        source: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        preferences: PickyPiInstallationPreferences? = nil
    ) -> Status {
        installedPackageSources(homeURL: homeURL, fileManager: fileManager, preferences: resolvedPreferences(preferences, homeURL: homeURL)).contains(source) ? .installed : .notInstalled
    }

    @discardableResult
    static func install(
        source: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        preferences: PickyPiInstallationPreferences? = nil,
        commandRunner: CommandRunner = runPiCommand
    ) -> Result<Void, CommandError> {
        runPi(command: "install", source: source, homeURL: homeURL, fileManager: fileManager, preferences: resolvedPreferences(preferences, homeURL: homeURL), commandRunner: commandRunner)
    }

    @discardableResult
    static func remove(
        source: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        preferences: PickyPiInstallationPreferences? = nil,
        commandRunner: CommandRunner = runPiCommand
    ) -> Result<Void, CommandError> {
        runPi(command: "remove", source: source, homeURL: homeURL, fileManager: fileManager, preferences: resolvedPreferences(preferences, homeURL: homeURL), commandRunner: commandRunner)
    }

    private static func runPi(
        command: String,
        source: String,
        homeURL: URL,
        fileManager: FileManager,
        preferences: PickyPiInstallationPreferences,
        commandRunner: CommandRunner
    ) -> Result<Void, CommandError> {
        do {
            let result = try commandRunner([command, source], homeURL, fileManager, preferences)
            guard result.exitCode == 0 else {
                return .failure(.failed(command: command, exitCode: result.exitCode, output: result.output))
            }
            return .success(())
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(.failed(command: command, exitCode: -1, output: error.localizedDescription))
        }
    }

    private static func installedPackageSources(homeURL: URL, fileManager: FileManager, preferences: PickyPiInstallationPreferences) -> Set<String> {
        let environment = homeURL.path == FileManager.default.homeDirectoryForCurrentUser.path
            ? ProcessInfo.processInfo.environment
            : [:]
        let settingsURL = PickyPiInstallation.settingsURL(preferences: preferences, homeURL: homeURL, environment: environment, fileManager: fileManager)
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["packages"] as? [String] else {
            return []
        }
        return Set(packages)
    }

    private static func runPiCommand(
        arguments: [String],
        homeURL: URL,
        fileManager: FileManager,
        preferences: PickyPiInstallationPreferences
    ) throws -> CommandResult {
        let resolved = PickyPiInstallation.resolve(preferences: preferences, homeURL: homeURL, fileManager: fileManager)
        guard let piURL = resolved.binaryURL, fileManager.isExecutableFile(atPath: piURL.path) else {
            throw CommandError.piMissing
        }

        let process = Process()
        process.executableURL = piURL
        process.arguments = arguments
        process.environment = PickyPiInstallation.mergedEnvironment(preferences: preferences, homeURL: homeURL, fileManager: fileManager)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, output: output)
    }

    private static func resolvedPreferences(_ preferences: PickyPiInstallationPreferences?, homeURL: URL) -> PickyPiInstallationPreferences {
        if let preferences { return preferences }
        guard homeURL.path == FileManager.default.homeDirectoryForCurrentUser.path else { return .init() }
        return PickyPiInstallation.preferences(from: PickySettingsStore().load())
    }
}
