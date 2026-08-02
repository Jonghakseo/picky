//
//  PickyCuratedPluginInstaller.swift
//  Picky
//
//  Installs curated third-party Pi packages through picky-agentd. The daemon
//  uses its bundled Pi SDK package manager, so users do not need a separate
//  `pi` CLI binary. Curated packages remain tracked in Pi's settings.json.
//

import Foundation

enum PickyCuratedPluginInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed(isPinned: Bool)

        var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }

        var isPinned: Bool {
            if case .installed(let isPinned) = self { return isPinned }
            return false
        }
    }

    enum CommandError: LocalizedError, Equatable {
        case failed(String)
        case timedOut
        case disconnected

        var errorDescription: String? {
            switch self {
            case .failed(let message):
                return message
            case .timedOut:
                return "Timed out waiting for package operation to finish."
            case .disconnected:
                return "picky-agentd disconnected while performing the package operation."
            }
        }
    }

    static func status(
        source: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        preferences: PickyPiInstallationPreferences? = nil
    ) -> Status {
        let preferences = resolvedPreferences(preferences, homeURL: homeURL)
        guard let installedSource = installedPackageSource(
            matching: source,
            homeURL: homeURL,
            fileManager: fileManager,
            preferences: preferences
        ) else {
            return .notInstalled
        }
        return .installed(isPinned: npmPackageIdentity(installedSource) != installedSource)
    }

    @discardableResult
    static func install(
        source: String,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 120_000_000_000
    ) async -> Result<Void, CommandError> {
        await run(operation: .install, source: source, client: client, timeoutNanoseconds: timeoutNanoseconds)
    }

    @discardableResult
    static func remove(
        source: String,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 120_000_000_000,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        preferences: PickyPiInstallationPreferences? = nil
    ) async -> Result<Void, CommandError> {
        await run(
            operation: .remove,
            source: installedPackageSource(
                matching: source,
                homeURL: homeURL,
                fileManager: fileManager,
                preferences: preferences
            ) ?? source,
            client: client,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    @discardableResult
    static func update(
        source: String,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 120_000_000_000
    ) async -> Result<Void, CommandError> {
        await run(operation: .update, source: source, client: client, timeoutNanoseconds: timeoutNanoseconds)
    }

    /// A best-effort background lookup. Callers keep failures silent but retain
    /// them so a later appearance can retry the request.
    static func checkUpdates(
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) async -> Result<Set<String>, CommandError> {
        let command = PickyCommandEnvelope(type: .checkPackageUpdates)
        let stream = client.events

        do {
            try await client.send(command)
            let sources = try await withThrowingTaskGroup(of: Set<String>.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    for await clientEvent in stream {
                        switch clientEvent {
                        case .protocolEvent(let envelope):
                            guard case .packageUpdatesAvailable(let result) = envelope.event,
                                  result.commandId == command.id else {
                                continue
                            }
                            return Set(result.sources)
                        case .disconnected:
                            throw CommandError.disconnected
                        case .connected, .recoverableError:
                            continue
                        }
                    }
                    throw CommandError.disconnected
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    try Task.checkCancellation()
                    throw CommandError.timedOut
                }
                return try await group.next() ?? []
            }
            return .success(sources)
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    private static func run(
        operation: PickyPackageOperation,
        source: String,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64
    ) async -> Result<Void, CommandError> {
        let commandType: PickyCommandType
        switch operation {
        case .install:
            commandType = .installPackage
        case .remove:
            commandType = .removePackage
        case .update:
            commandType = .updatePackage
        }
        let command = PickyCommandEnvelope(type: commandType, source: source)
        // Subscribe before sending so a fast daemon completion cannot be missed.
        let stream = client.events

        do {
            try await client.send(command)
            try await withThrowingTaskGroup(of: Void.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    for await clientEvent in stream {
                        switch clientEvent {
                        case .protocolEvent(let envelope):
                            guard case .packageOperationCompleted(let result) = envelope.event,
                                  result.requestId == command.id,
                                  result.operation == operation,
                                  result.source == source else {
                                continue
                            }
                            guard result.ok else {
                                throw CommandError.failed(result.errorMessage ?? "Package operation failed.")
                            }
                            return
                        case .disconnected:
                            throw CommandError.disconnected
                        case .connected, .recoverableError:
                            continue
                        }
                    }
                    throw CommandError.disconnected
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    try Task.checkCancellation()
                    throw CommandError.timedOut
                }
                _ = try await group.next()
            }
            return .success(())
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    private static func installedPackageSource(
        matching source: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        preferences: PickyPiInstallationPreferences? = nil
    ) -> String? {
        let preferences = resolvedPreferences(preferences, homeURL: homeURL)
        let environment = homeURL.path == FileManager.default.homeDirectoryForCurrentUser.path
            ? ProcessInfo.processInfo.environment
            : [:]
        let settingsURL = PickyPiInstallation.settingsURL(preferences: preferences, homeURL: homeURL, environment: environment, fileManager: fileManager)
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["packages"] as? [String] else {
            return nil
        }
        let identity = npmPackageIdentity(source)
        return packages.first { npmPackageIdentity($0) == identity }
    }

    private static func npmPackageIdentity(_ source: String) -> String {
        guard source.hasPrefix("npm:") else { return source }
        let package = source.dropFirst("npm:".count)
        guard let versionIndex = package.lastIndex(of: "@"),
              versionIndex != package.startIndex,
              versionIndex < package.index(before: package.endIndex) else {
            return source
        }
        return "npm:" + String(package[..<versionIndex])
    }

    private static func resolvedPreferences(_ preferences: PickyPiInstallationPreferences?, homeURL: URL) -> PickyPiInstallationPreferences {
        if let preferences { return preferences }
        guard homeURL.path == FileManager.default.homeDirectoryForCurrentUser.path else { return .init() }
        return PickyPiInstallation.preferences(from: PickySettingsStore().load())
    }
}
