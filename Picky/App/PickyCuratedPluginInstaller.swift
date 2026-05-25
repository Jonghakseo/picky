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
                return "Pi CLI was not found at ~/.pi/agent/bin/pi. Install Pi first, then try again."
            case .failed(let command, let exitCode, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "`pi \(command)` failed with exit code \(exitCode)."
                }
                return "`pi \(command)` failed with exit code \(exitCode): \(detail)"
            }
        }
    }

    typealias CommandRunner = (_ arguments: [String], _ homeURL: URL, _ fileManager: FileManager) throws -> CommandResult

    static func status(
        source: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Status {
        installedPackageSources(homeURL: homeURL, fileManager: fileManager).contains(source) ? .installed : .notInstalled
    }

    @discardableResult
    static func install(
        source: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        commandRunner: CommandRunner = runPiCommand
    ) -> Result<Void, CommandError> {
        runPi(command: "install", source: source, homeURL: homeURL, fileManager: fileManager, commandRunner: commandRunner)
    }

    @discardableResult
    static func remove(
        source: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        commandRunner: CommandRunner = runPiCommand
    ) -> Result<Void, CommandError> {
        runPi(command: "remove", source: source, homeURL: homeURL, fileManager: fileManager, commandRunner: commandRunner)
    }

    private static func runPi(
        command: String,
        source: String,
        homeURL: URL,
        fileManager: FileManager,
        commandRunner: CommandRunner
    ) -> Result<Void, CommandError> {
        do {
            let result = try commandRunner([command, source], homeURL, fileManager)
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

    private static func installedPackageSources(homeURL: URL, fileManager: FileManager) -> Set<String> {
        let settingsURL = settingsURL(homeURL: homeURL)
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["packages"] as? [String] else {
            return []
        }
        return Set(packages)
    }

    private static func settingsURL(homeURL: URL) -> URL {
        homeURL.appendingPathComponent(".pi/agent/settings.json", isDirectory: false)
    }

    private static func runPiCommand(
        arguments: [String],
        homeURL: URL,
        fileManager: FileManager
    ) throws -> CommandResult {
        let preferredPi = homeURL.appendingPathComponent(".pi/agent/bin/pi", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: preferredPi.path) else {
            throw CommandError.piMissing
        }

        let process = Process()
        process.executableURL = preferredPi
        process.arguments = arguments
        process.environment = mergedEnvironment(homeURL: homeURL)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, output: output)
    }

    private static func mergedEnvironment(homeURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"].map { ":\($0)" } ?? ""
        environment["PATH"] = [
            homeURL.appendingPathComponent(".pi/agent/bin", isDirectory: true).path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":") + existingPath
        return environment
    }
}
