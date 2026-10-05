//
//  PickyRemoteGatewayLauncher.swift
//  Picky
//
//  Owns the remote gateway child process (`agentd/dist/gateway/main.js`).
//  Deliberately separate from `PickyAgentDaemonPool`: the gateway is not a
//  daemon role, it is the single process that accepts input from outside the
//  Mac and it must be startable and stoppable on its own.
//

import Foundation
import Security

/// Where the gateway entry point was found, and how to run it.
struct PickyRemoteGatewayCommand: Equatable {
    var executableURL: URL
    var arguments: [String]
    var workingDirectory: URL
    /// Executable that must be resolvable through PATH (`/usr/bin/env` form).
    var requiredExecutableName: String?
}

enum PickyRemoteGatewayLaunchError: LocalizedError, Equatable {
    case gatewayNotBuilt(String)
    case runtimeNotFound(String)
    case missingExecutable(String)

    var errorDescription: String? {
        switch self {
        case .gatewayNotBuilt(let path):
            L10n.t("settings.remote.error.notBuilt", path)
        case .runtimeNotFound(let path):
            L10n.t("settings.remote.error.runtimeMissing", path)
        case .missingExecutable(let name):
            L10n.t("settings.remote.error.missingExecutable", name)
        }
    }
}

enum PickyRemoteGatewayCommandResolver {
    /// Mirrors `PickyAgentDaemonConfiguration`'s runtime resolution so the
    /// gateway always runs out of the same agentd tree as the daemons.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) throws -> PickyRemoteGatewayCommand {
        let location = PickyAgentdRootResolver.resolveRuntimeLocation(
            environment: environment,
            bundleResourceURL: bundleResourceURL,
            fileManager: fileManager
        )
        switch location {
        case .externalSource(let root):
            // Development tree: dist/ may be stale or absent, so prefer the
            // compiled entry when it exists and fall back to tsx otherwise.
            let compiled = root.appendingPathComponent("dist/gateway/main.js")
            if fileManager.fileExists(atPath: compiled.path) {
                return nodeCommand(
                    entryPoint: compiled,
                    root: root,
                    environment: environment,
                    bundleResourceURL: bundleResourceURL,
                    fileManager: fileManager
                )
            }
            let source = root.appendingPathComponent("src/gateway/main.ts")
            guard fileManager.fileExists(atPath: source.path) else {
                throw PickyRemoteGatewayLaunchError.gatewayNotBuilt(compiled.path)
            }
            return PickyRemoteGatewayCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["pnpm", "--dir", root.path, "exec", "tsx", "src/gateway/main.ts"],
                workingDirectory: root,
                requiredExecutableName: "pnpm"
            )
        case .externalCompiled(let root), .bundled(let root):
            let compiled = root.appendingPathComponent("dist/gateway/main.js")
            guard fileManager.fileExists(atPath: compiled.path) else {
                throw PickyRemoteGatewayLaunchError.gatewayNotBuilt(compiled.path)
            }
            return nodeCommand(
                entryPoint: compiled,
                root: root,
                environment: environment,
                bundleResourceURL: bundleResourceURL,
                fileManager: fileManager
            )
        case .missingExternal(let root), .missingBundled(let root):
            throw PickyRemoteGatewayLaunchError.runtimeNotFound(root.path)
        }
    }

    private static func nodeCommand(
        entryPoint: URL,
        root: URL,
        environment: [String: String],
        bundleResourceURL: URL?,
        fileManager: FileManager
    ) -> PickyRemoteGatewayCommand {
        switch PickyAgentDaemonConfiguration.resolveNodeExecutable(
            bundleResourceURL: bundleResourceURL,
            environment: environment,
            fileManager: fileManager
        ) {
        case .absolute(let nodeURL, _):
            return PickyRemoteGatewayCommand(
                executableURL: nodeURL,
                arguments: [entryPoint.path],
                workingDirectory: root,
                requiredExecutableName: nil
            )
        case .viaEnv:
            return PickyRemoteGatewayCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["node", entryPoint.path],
                workingDirectory: root,
                requiredExecutableName: "node"
            )
        }
    }

    /// Environment handed to the gateway. The hub token never touches disk or
    /// the command line; it exists only here and in the hub client.
    static func environment(
        port: Int,
        hubToken: String,
        appSupportRoot: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["PICKY_GATEWAY_PORT"] = String(port)
        env["PICKY_GATEWAY_HUB_TOKEN"] = hubToken
        env["PICKY_APP_SUPPORT_DIR"] = appSupportRoot.path
        env["PICKY_AGENTD_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["PATH"] = PickyAgentDaemonConfiguration.augmentedExecutablePATH(from: base)
        return env
    }

    /// 32 random bytes, base64url without padding so it survives any env/header
    /// round trip unescaped.
    static func randomHubToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Lifecycle states the settings UI renders.
enum PickyRemoteGatewayState: Equatable {
    case stopped
    case starting
    case running(port: Int)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running: true
        case .stopped, .failed: false
        }
    }
}

@MainActor
final class PickyRemoteGatewayLauncher {
    /// `picky-gateway listening on 127.0.0.1:<port>` marks readiness.
    static let readyLinePrefix = "picky-gateway listening on 127.0.0.1:"
    private static let maxLogFileSize: Int64 = 5 * 1024 * 1024
    private static let maxLogRotations = 3
    private static let restartBackoffSeconds: [TimeInterval] = [1, 2, 5, 10, 30]

    private(set) var state: PickyRemoteGatewayState = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((PickyRemoteGatewayState) -> Void)?

    private let logDirectory: URL
    private let fileManager: FileManager
    private var process: Process?
    private var restartTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var stdoutBuffer: [UInt8] = []
    private var logFileSizes: [String: Int64] = [:]
    private var launchGeneration = 0
    private var desiredPort: Int?
    private var desiredToken: String?
    private var desiredAppSupportRoot: URL?

    init(appSupportRoot: URL = PickyAppSupport.defaultRoot(), fileManager: FileManager = .default) {
        self.logDirectory = appSupportRoot.appendingPathComponent("Logs", isDirectory: true)
        self.fileManager = fileManager
    }

    var isRunning: Bool { process?.isRunning == true }

    func start(port: Int, hubToken: String, appSupportRoot: URL) {
        desiredPort = port
        desiredToken = hubToken
        desiredAppSupportRoot = appSupportRoot
        consecutiveFailures = 0
        launch()
    }

    func stop() {
        desiredPort = nil
        desiredToken = nil
        desiredAppSupportRoot = nil
        restartTask?.cancel()
        restartTask = nil
        launchGeneration &+= 1
        terminateProcess()
        state = .stopped
    }

    /// Called on app termination. Same as `stop()` but waits briefly so the
    /// gateway's own cleanup runs before the app disappears.
    func stopAndWaitForExit() {
        let running = process
        stop()
        guard let running, running.isRunning else { return }
        running.waitUntilExit()
    }

    private func terminateProcess() {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminationHandler = nil
        process.terminate()
        self.process = nil
    }

    private func launch() {
        guard let port = desiredPort, let token = desiredToken, let appSupportRoot = desiredAppSupportRoot else { return }
        terminateProcess()
        stdoutBuffer.removeAll(keepingCapacity: true)
        state = .starting

        let command: PickyRemoteGatewayCommand
        do {
            command = try PickyRemoteGatewayCommandResolver.resolve()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.environment = PickyRemoteGatewayCommandResolver.environment(
            port: port,
            hubToken: token,
            appSupportRoot: appSupportRoot
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        launchGeneration &+= 1
        let generation = launchGeneration
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.handleStdout(data, generation: generation) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.append(data, to: "gateway.stderr.log") }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in self?.handleExit(status: status, generation: generation) }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
            state = .failed(error.localizedDescription)
            scheduleRestart()
        }
    }

    private func handleStdout(_ data: Data, generation: Int) {
        guard generation == launchGeneration else { return }
        append(data, to: "gateway.stdout.log")
        stdoutBuffer.append(contentsOf: data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineBytes = Array(stdoutBuffer[..<newlineIndex])
            stdoutBuffer.removeSubrange(0...newlineIndex)
            let trimmed = lineBytes.last == 0x0D ? Array(lineBytes.dropLast()) : lineBytes
            guard let line = String(bytes: trimmed, encoding: .utf8) else { continue }
            if let port = Self.readyPort(from: line) {
                consecutiveFailures = 0
                state = .running(port: port)
            }
        }
    }

    static func readyPort(from line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(readyLinePrefix) else { return nil }
        return Int(trimmed.dropFirst(readyLinePrefix.count).prefix(while: \.isNumber))
    }

    private func handleExit(status: Int32, generation: Int) {
        guard generation == launchGeneration else { return }
        process = nil
        guard desiredPort != nil else {
            state = .stopped
            return
        }
        state = .failed(L10n.t("settings.remote.error.exited", String(status)))
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard desiredPort != nil else { return }
        let index = min(consecutiveFailures, Self.restartBackoffSeconds.count - 1)
        let delay = Self.restartBackoffSeconds[index]
        consecutiveFailures += 1
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.desiredPort != nil else { return }
            self.launch()
        }
    }

    // MARK: - Logs

    private func append(_ data: Data, to fileName: String) {
        guard !data.isEmpty else { return }
        let url = logDirectory.appendingPathComponent(fileName)
        rotateLogIfNeeded(url: url, fileName: fileName)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        logFileSizes[fileName] = (logFileSizes[fileName] ?? 0) + Int64(data.count)
    }

    private func rotateLogIfNeeded(url: URL, fileName: String) {
        if logFileSizes[fileName] == nil {
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            logFileSizes[fileName] = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard (logFileSizes[fileName] ?? 0) >= Self.maxLogFileSize else { return }
        let dir = url.deletingLastPathComponent()
        try? fileManager.removeItem(at: dir.appendingPathComponent("\(fileName).\(Self.maxLogRotations)"))
        for index in stride(from: Self.maxLogRotations - 1, through: 1, by: -1) {
            let from = dir.appendingPathComponent("\(fileName).\(index)")
            let to = dir.appendingPathComponent("\(fileName).\(index + 1)")
            guard fileManager.fileExists(atPath: from.path) else { continue }
            try? fileManager.removeItem(at: to)
            try? fileManager.moveItem(at: from, to: to)
        }
        let firstBackup = dir.appendingPathComponent("\(fileName).1")
        try? fileManager.removeItem(at: firstBackup)
        try? fileManager.moveItem(at: url, to: firstBackup)
        logFileSizes[fileName] = 0
    }
}
