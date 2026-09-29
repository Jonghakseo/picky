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

    /// A package operation agentd finished without success. `detail` is the raw
    /// daemon/npm text; agentd already logs it, so the UI never shows it.
    struct Rejection: Equatable {
        let operation: PickyPackageOperation
        let code: PickyPackageErrorCode?
        let detail: String
        let packageChanged: Bool
    }

    enum CommandError: LocalizedError, Equatable {
        /// App-authored text that is already written for people.
        case failed(String)
        case rejected(Rejection)
        case timedOut
        case disconnected

        /// User-facing wording. Raw daemon output stays in `Rejection.detail` and the agentd log.
        var errorDescription: String? {
            switch self {
            case .failed(let message):
                return message
            case .rejected(let rejection):
                switch rejection.code {
                case .duplicate: return L10n.t("hub.plugins.error.duplicate")
                case .held: return L10n.t("hub.plugins.error.held")
                case .timeout: return L10n.t("hub.plugins.error.timeout")
                case nil:
                    if rejection.packageChanged { return L10n.t("hub.plugins.error.partial") }
                    switch rejection.operation {
                    case .install: return L10n.t("hub.plugins.error.failed.install")
                    case .remove: return L10n.t("hub.plugins.error.failed.remove")
                    case .update: return L10n.t("hub.plugins.error.failed.update")
                    case .setup: return L10n.t("hub.plugins.error.failed.setup")
                    }
                }
            case .timedOut:
                return L10n.t("hub.plugins.error.timeout")
            case .disconnected:
                return L10n.t("hub.plugins.error.disconnected")
            }
        }

        var packageChanged: Bool {
            if case .rejected(let rejection) = self { return rejection.packageChanged }
            return false
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
        return .installed(isPinned: isPinnedPackageSource(installedSource))
    }

    /// Reads the installed package manifest from Pi's package-manager layout.
    /// A configured package without a matching local manifest has no trustworthy
    /// installed version, so callers intentionally render no version in that case.
    static func installedVersion(
        source: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        preferences: PickyPiInstallationPreferences? = nil
    ) -> String? {
        let preferences = resolvedPreferences(preferences, homeURL: homeURL)
        guard installedPackageSource(
            matching: source,
            homeURL: homeURL,
            fileManager: fileManager,
            preferences: preferences
        ) != nil,
        let packageName = npmPackageName(in: source) else {
            return nil
        }

        let environment = homeURL.path == FileManager.default.homeDirectoryForCurrentUser.path
            ? ProcessInfo.processInfo.environment
            : [:]
        let agentDirectory = PickyPiInstallation.resolve(
            preferences: preferences,
            homeURL: homeURL,
            environment: environment,
            fileManager: fileManager
        ).codingAgentDirURL
        let manifestURL = packageName
            .split(separator: "/")
            .reduce(agentDirectory.appendingPathComponent("npm/node_modules", isDirectory: true)) { directory, component in
                directory.appendingPathComponent(String(component), isDirectory: true)
            }
            .appendingPathComponent("package.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["name"] as? String == packageName,
              let version = manifest["version"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return version
    }

    @discardableResult
    static func install(
        source: String,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 180_000_000_000
    ) async -> Result<Void, CommandError> {
        await run(operation: .install, source: source, client: client, timeoutNanoseconds: timeoutNanoseconds)
    }

    @discardableResult
    static func remove(
        source: String,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 180_000_000_000,
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
    // Allow the package mutation (110s) and cron's bounded runtime drain (900s)
    // to finish before presenting a transport timeout.
    static func update(
        source: String,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 1_020_000_000_000
    ) async -> Result<Void, CommandError> {
        await run(operation: .update, source: source, client: client, timeoutNanoseconds: timeoutNanoseconds)
    }

    @discardableResult
    static func setup(
        source: String,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 180_000_000_000
    ) async -> Result<Void, CommandError> {
        await run(operation: .setup, source: source, client: client, timeoutNanoseconds: timeoutNanoseconds)
    }

    /// A best-effort background lookup. Callers keep failures silent but retain
    /// them so a later appearance can retry the request.
    static func checkUpdates(
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) async -> Result<Set<String>, CommandError> {
        await query(
            PickyCommandEnvelope(type: .checkPackageUpdates),
            client: client,
            timeoutNanoseconds: timeoutNanoseconds
        ) { event, commandID in
            guard case .packageUpdatesAvailable(let result) = event, result.commandId == commandID else { return nil }
            if result.failed == true { throw CommandError.failed("Package update check failed.") }
            return Set(result.sources)
        }
    }

    /// Asks agentd which other installed tools or skills share a name with
    /// what these curated packages provide. agentd refuses such installs too;
    /// this lookup only lets the catalog explain the block before a click.
    static func inspectConflicts(
        sources: [String],
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) async -> Result<[PickyPackageConflict], CommandError> {
        guard !sources.isEmpty else { return .success([]) }
        return await query(
            PickyCommandEnvelope(type: .inspectPackageConflicts, sources: sources),
            client: client,
            timeoutNanoseconds: timeoutNanoseconds
        ) { event, commandID in
            guard case .packageConflicts(let result) = event, result.commandId == commandID else { return nil }
            if result.failed == true { throw CommandError.failed("Package conflict check failed.") }
            return result.conflicts
        }
    }

    /// Sends one read-only command and waits for the event whose `match` returns a value.
    private static func query<Value: Sendable>(
        _ command: PickyCommandEnvelope,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64,
        match: @escaping @Sendable (PickyEvent, String) throws -> Value?
    ) async -> Result<Value, CommandError> {
        let stream = await client.events
        let commandID = command.id
        do {
            try await client.send(command)
            let value = try await withThrowingTaskGroup(of: Value.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    for await clientEvent in stream {
                        switch clientEvent {
                        case .protocolEvent(let envelope):
                            if let value = try match(envelope.event, commandID) { return value }
                        case .disconnected:
                            throw CommandError.disconnected
                        case .connected, .sessionProjectionBootstrapCompletion, .recoverableError:
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
                guard let value = try await group.next() else { throw CommandError.disconnected }
                return value
            }
            return .success(value)
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
        case .setup:
            commandType = .setupPackage
        }
        let command = PickyCommandEnvelope(type: commandType, source: source)
        // Subscribe before sending so a fast daemon completion cannot be missed.
        let stream = await client.events

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
                                throw CommandError.rejected(Rejection(
                                    operation: operation,
                                    code: result.code,
                                    detail: result.errorMessage ?? "Package operation failed.",
                                    packageChanged: result.packageChanged == true
                                ))
                            }
                            return
                        case .disconnected:
                            throw CommandError.disconnected
                        case .connected, .sessionProjectionBootstrapCompletion, .recoverableError:
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
            // Sending failed before agentd saw the request; nothing changed.
            return .failure(.rejected(Rejection(operation: operation, code: nil, detail: error.localizedDescription, packageChanged: false)))
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
        guard let versionIndex = npmVersionIndex(in: source) else { return source }
        return "npm:" + String(source.dropFirst("npm:".count)[..<versionIndex])
    }

    private static func npmPackageName(in source: String) -> String? {
        guard source.hasPrefix("npm:") else { return nil }
        let package = source.dropFirst("npm:".count)
        guard !package.isEmpty else { return nil }
        guard let versionIndex = npmVersionIndex(in: source) else { return String(package) }
        return String(package[..<versionIndex])
    }

    private static func isPinnedPackageSource(_ source: String) -> Bool {
        guard let versionIndex = npmVersionIndex(in: source) else { return false }
        let package = source.dropFirst("npm:".count)
        let version = String(package[package.index(after: versionIndex)...])
        return version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }

    private static func npmVersionIndex(in source: String) -> String.Index? {
        guard source.hasPrefix("npm:") else { return nil }
        let package = source.dropFirst("npm:".count)
        guard let versionIndex = package.lastIndex(of: "@"),
              versionIndex != package.startIndex,
              versionIndex < package.index(before: package.endIndex) else {
            return nil
        }
        return versionIndex
    }

    private static func resolvedPreferences(_ preferences: PickyPiInstallationPreferences?, homeURL: URL) -> PickyPiInstallationPreferences {
        if let preferences { return preferences }
        guard homeURL.path == FileManager.default.homeDirectoryForCurrentUser.path else { return .init() }
        return PickyPiInstallation.preferences(from: PickySettingsStore().load())
    }
}
