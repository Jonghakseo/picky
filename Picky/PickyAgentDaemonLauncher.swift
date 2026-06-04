//
//  PickyAgentDaemonLauncher.swift
//  Picky
//
//  Child-process supervisor for local picky-agentd.
//

import Combine
import Darwin
import Foundation

enum PickyAgentDaemonRole: Equatable {
    case primary
    /// Per-Pickle child daemon (Phase 2 of the per-Pickle agentd plan). Hosts a single Pickle
    /// session keyed by sessionId, binds on a random port (env PICKY_AGENTD_PORT is omitted), and
    /// uses sessionCwd as the workspace cwd so `pi-extension-claude-mcp-bridge` walks up from
    /// the correct directory. `primaryUrl` is reserved for Phase 3 RPC mirroring.
    case child(sessionId: String, sessionCwd: String, primaryUrl: String?)
}

enum PickyResolvedNodeExecutable: Equatable {
    /// Spawn an executable by absolute path, bypassing `/usr/bin/env` and PATH lookup.
    case absolute(URL, source: Source)
    /// Preserve the historical launch path where `/usr/bin/env` finds `node` on PATH.
    case viaEnv

    enum Source: String, Equatable {
        case override
        case bundled
    }
}

enum PickyNodeSource: String, Codable, Equatable {
    /// PICKY_NODE_PATH override.
    case override
    /// app Resources/agentd-runtime/bin/node.
    case bundled
    /// `/usr/bin/env` resolves node from PATH.
    case external
    /// Node is not the direct executable for this launch path (for example pnpm source mode).
    case absent
}

struct PickyAgentDaemonConfiguration: Equatable {
    var port: Int
    var token: String
    var appSupportRoot: URL
    var defaultCwd: String
    var mainAgentCwd: String = FileManager.default.homeDirectoryForCurrentUser.path
    var mainAgentThinkingLevel: PickyMainAgentThinkingLevel = .medium
    var mainAgentModelPattern: String = ""
    var pickleAgentThinkingLevel: PickyPickleAgentThinkingLevel = .automatic
    var pickleAgentModelPattern: String = ""
    var mainAgentRuntimeMode: PickyMainAgentRuntimeMode = .pi
    var piBinaryPath: String = ""
    var piCodingAgentDir: String = ""
    var runtime: String?
    var workingDirectory: URL
    var executableURL: URL
    var arguments: [String]
    var nodeSource: PickyNodeSource = .absent
    var requiredExecutableName: String? = nil
    var requiredAgentdEntryPoint: String? = nil
    var missingAgentdPackageMessage: String? = nil
    var missingAgentdEntryPointMessage: String? = nil
    var role: PickyAgentDaemonRole = .primary
    /// Optional override for the host process env used as the base of `environment`. Tests
    /// inject a deterministic dictionary so they can prove that scrub logic (removing
    /// `PICKY_AGENTD_PORT` in child mode, `PICKY_AGENTD_SESSION_*` in primary mode, etc.)
    /// actually drops keys that exist in the source env. Production primary callers leave
    /// this nil so the `environment` getter re-reads `ProcessInfo.processInfo.environment`
    /// on every launch (preserving the pre-Phase-2 behaviour where a launcher restart picks
    /// up env changes); child callers always set it because the child config is built once
    /// per spawn from a known env snapshot anyway.
    var baseEnvironment: [String: String]? = nil

    static func development(
        port: Int = 17631,
        token: String = UUID().uuidString,
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        defaultCwd: String = FileManager.default.homeDirectoryForCurrentUser.path,
        mainAgentCwd: String = FileManager.default.homeDirectoryForCurrentUser.path,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel = .medium,
        mainAgentModelPattern: String = "",
        pickleAgentThinkingLevel: PickyPickleAgentThinkingLevel = .automatic,
        pickleAgentModelPattern: String = "",
        mainAgentRuntimeMode: PickyMainAgentRuntimeMode = .pi,
        piBinaryPath: String = "",
        piCodingAgentDir: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> PickyAgentDaemonConfiguration {
        let location = PickyAgentdRootResolver.resolveRuntimeLocation(
            environment: environment,
            bundleResourceURL: bundleResourceURL,
            fileManager: fileManager
        )
        return Self.configuration(
            for: location,
            port: port,
            token: token,
            appSupportRoot: appSupportRoot,
            defaultCwd: defaultCwd,
            mainAgentCwd: mainAgentCwd,
            mainAgentThinkingLevel: mainAgentThinkingLevel,
            mainAgentModelPattern: mainAgentModelPattern,
            pickleAgentThinkingLevel: pickleAgentThinkingLevel,
            pickleAgentModelPattern: pickleAgentModelPattern,
            mainAgentRuntimeMode: mainAgentRuntimeMode,
            piBinaryPath: piBinaryPath,
            piCodingAgentDir: piCodingAgentDir,
            runtime: environment["PICKY_AGENTD_RUNTIME"],
            environment: environment,
            bundleResourceURL: bundleResourceURL,
            fileManager: fileManager
        )
        // Intentionally do not stash `environment` as baseEnvironment for primary mode:
        // the lazy daemonConfiguration in PickyApp.swift is built once at app launch, and
        // capturing the env dictionary here would freeze the launcher's environment view
        // to the app-start snapshot. Leave baseEnvironment nil so the getter keeps reading
        // ProcessInfo.processInfo.environment on every launch, matching pre-Phase-2
        // behaviour. Tests that need a deterministic env can set baseEnvironment directly
        // on the returned configuration before reading `environment`.
    }

    private static func configuration(
        for location: PickyAgentdRuntimeLocation,
        port: Int,
        token: String,
        appSupportRoot: URL,
        defaultCwd: String,
        mainAgentCwd: String,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel,
        mainAgentModelPattern: String,
        pickleAgentThinkingLevel: PickyPickleAgentThinkingLevel,
        pickleAgentModelPattern: String,
        mainAgentRuntimeMode: PickyMainAgentRuntimeMode,
        piBinaryPath: String,
        piCodingAgentDir: String,
        runtime: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default,
        baseEnvironment: [String: String]? = nil
    ) -> PickyAgentDaemonConfiguration {
        func nodeCommand(entryPoint: String) -> (URL, [String], String?, PickyNodeSource) {
            let resolvedNode = resolveNodeExecutable(
                bundleResourceURL: bundleResourceURL,
                environment: environment,
                fileManager: fileManager
            )
            switch resolvedNode {
            case .absolute(let nodeURL, let source):
                return (nodeURL, [entryPoint], nil, nodeSource(for: source))
            case .viaEnv:
                return (URL(fileURLWithPath: "/usr/bin/env"), ["node", entryPoint], "node", .external)
            }
        }

        switch location {
        case .externalSource(let root):
            var config = PickyAgentDaemonConfiguration(
                port: port,
                token: token,
                appSupportRoot: appSupportRoot,
                defaultCwd: defaultCwd,
                mainAgentCwd: mainAgentCwd,
                mainAgentThinkingLevel: mainAgentThinkingLevel,
                mainAgentModelPattern: mainAgentModelPattern,
                pickleAgentThinkingLevel: pickleAgentThinkingLevel,
                pickleAgentModelPattern: pickleAgentModelPattern,
                mainAgentRuntimeMode: mainAgentRuntimeMode,
                piBinaryPath: piBinaryPath,
                piCodingAgentDir: piCodingAgentDir,
                runtime: runtime,
                workingDirectory: root,
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["pnpm", "--dir", root.path, "exec", "tsx", "src/index.ts"],
                requiredExecutableName: "pnpm",
                requiredAgentdEntryPoint: "src/index.ts"
            )
            config.baseEnvironment = baseEnvironment
            return config
        case .externalCompiled(let root), .bundled(let root):
            let entryPoint = root.appendingPathComponent("dist/index.js").path
            let command = nodeCommand(entryPoint: entryPoint)
            var config = PickyAgentDaemonConfiguration(
                port: port,
                token: token,
                appSupportRoot: appSupportRoot,
                defaultCwd: defaultCwd,
                mainAgentCwd: mainAgentCwd,
                mainAgentThinkingLevel: mainAgentThinkingLevel,
                mainAgentModelPattern: mainAgentModelPattern,
                pickleAgentThinkingLevel: pickleAgentThinkingLevel,
                pickleAgentModelPattern: pickleAgentModelPattern,
                mainAgentRuntimeMode: mainAgentRuntimeMode,
                piBinaryPath: piBinaryPath,
                piCodingAgentDir: piCodingAgentDir,
                runtime: runtime,
                workingDirectory: root,
                executableURL: command.0,
                arguments: command.1,
                nodeSource: command.3,
                requiredExecutableName: command.2,
                requiredAgentdEntryPoint: "dist/index.js"
            )
            config.baseEnvironment = baseEnvironment
            return config
        case .missingExternal(let root):
            let message = "PICKY_AGENTD_ROOT does not contain a runnable picky-agentd package at \(root.path). Expected src/index.ts for development or dist/index.js for a compiled runtime."
            let command = nodeCommand(entryPoint: root.appendingPathComponent("dist/index.js").path)
            var config = PickyAgentDaemonConfiguration(
                port: port,
                token: token,
                appSupportRoot: appSupportRoot,
                defaultCwd: defaultCwd,
                mainAgentCwd: mainAgentCwd,
                mainAgentThinkingLevel: mainAgentThinkingLevel,
                mainAgentModelPattern: mainAgentModelPattern,
                pickleAgentThinkingLevel: pickleAgentThinkingLevel,
                pickleAgentModelPattern: pickleAgentModelPattern,
                mainAgentRuntimeMode: mainAgentRuntimeMode,
                piBinaryPath: piBinaryPath,
                piCodingAgentDir: piCodingAgentDir,
                runtime: runtime,
                workingDirectory: root,
                executableURL: command.0,
                arguments: command.1,
                nodeSource: command.3,
                requiredExecutableName: command.2,
                requiredAgentdEntryPoint: "dist/index.js",
                missingAgentdPackageMessage: message,
                missingAgentdEntryPointMessage: message
            )
            config.baseEnvironment = baseEnvironment
            return config
        case .missingBundled(let root):
            let message = "Bundled picky-agentd was not found in app resources at \(root.path). Package Picky with scripts/package-signed-app.sh or set PICKY_AGENTD_ROOT to a local agentd directory."
            let command = nodeCommand(entryPoint: root.appendingPathComponent("dist/index.js").path)
            var config = PickyAgentDaemonConfiguration(
                port: port,
                token: token,
                appSupportRoot: appSupportRoot,
                defaultCwd: defaultCwd,
                mainAgentCwd: mainAgentCwd,
                mainAgentThinkingLevel: mainAgentThinkingLevel,
                mainAgentModelPattern: mainAgentModelPattern,
                pickleAgentThinkingLevel: pickleAgentThinkingLevel,
                pickleAgentModelPattern: pickleAgentModelPattern,
                mainAgentRuntimeMode: mainAgentRuntimeMode,
                piBinaryPath: piBinaryPath,
                piCodingAgentDir: piCodingAgentDir,
                runtime: runtime,
                workingDirectory: root,
                executableURL: command.0,
                arguments: command.1,
                nodeSource: command.3,
                requiredExecutableName: command.2,
                requiredAgentdEntryPoint: "dist/index.js",
                missingAgentdPackageMessage: message,
                missingAgentdEntryPointMessage: message
            )
            config.baseEnvironment = baseEnvironment
            return config
        }
    }

    /// Phase 2 of the per-Pickle agentd plan: build a configuration for a single-session
    /// child daemon. Inherits the same runtime location resolution as the primary so the child
    /// runs the exact same agentd binary, but flips role to `.child` and clears the main-agent
    /// env so the bootstrap takes the child-only code path.
    static func child(
        sessionId: String,
        sessionCwd: String,
        primaryUrl: String?,
        token: String,
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        pickleAgentThinkingLevel: PickyPickleAgentThinkingLevel = .automatic,
        pickleAgentModelPattern: String = "",
        piBinaryPath: String = "",
        piCodingAgentDir: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default,
        baseEnvironmentForEnvGetter: [String: String]? = nil
    ) -> PickyAgentDaemonConfiguration {
        let location = PickyAgentdRootResolver.resolveRuntimeLocation(
            environment: environment,
            bundleResourceURL: bundleResourceURL,
            fileManager: fileManager
        )
        var configuration = Self.configuration(
            for: location,
            port: 0,
            token: token,
            appSupportRoot: appSupportRoot,
            defaultCwd: sessionCwd,
            mainAgentCwd: sessionCwd,
            mainAgentThinkingLevel: .medium,
            mainAgentModelPattern: "",
            pickleAgentThinkingLevel: pickleAgentThinkingLevel,
            pickleAgentModelPattern: pickleAgentModelPattern,
            mainAgentRuntimeMode: .pi,
            piBinaryPath: piBinaryPath,
            piCodingAgentDir: piCodingAgentDir,
            runtime: environment["PICKY_AGENTD_RUNTIME"],
            environment: environment,
            bundleResourceURL: bundleResourceURL,
            fileManager: fileManager
        )
        configuration.role = .child(sessionId: sessionId, sessionCwd: sessionCwd, primaryUrl: primaryUrl)
        configuration.baseEnvironment = baseEnvironmentForEnvGetter ?? environment
        return configuration
    }

    var environment: [String: String] {
        var env = baseLaunchEnvironment()
        switch role {
        case .primary:
            applyPrimaryEnvironment(to: &env)
        case .child(let sessionId, let sessionCwd, let primaryUrl):
            applyChildEnvironment(to: &env, sessionId: sessionId, sessionCwd: sessionCwd, primaryUrl: primaryUrl)
        }
        if let runtime { env["PICKY_AGENTD_RUNTIME"] = runtime }
        return env
    }

    private func baseLaunchEnvironment() -> [String: String] {
        var env = baseEnvironment ?? ProcessInfo.processInfo.environment
        env["PATH"] = Self.augmentedExecutablePATH(from: env)
        env["PICKY_AGENTD_TOKEN"] = token
        env["PICKY_AGENTD_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["PICKY_APP_SUPPORT_DIR"] = appSupportRoot.path
        let piAgentDir = PickyPiInstallation.resolve(
            preferences: PickyPiInstallationPreferences(binaryPath: piBinaryPath, codingAgentDir: piCodingAgentDir),
            environment: env
        ).codingAgentDirURL
        env[PickyPiInstallation.environmentAgentDirKey] = piAgentDir.path
        let piBinPath = piAgentDir.appendingPathComponent("bin", isDirectory: true).path
        if !(env["PATH"] ?? "").split(separator: ":").contains(Substring(piBinPath)) {
            env["PATH"] = "\(piBinPath):\(env["PATH"] ?? "")"
        }
        return env
    }

    private func applyPrimaryEnvironment(to env: inout [String: String]) {
        // PICKY_AGENTD_MODE is set first so the bootstrap's mode parser sees a deterministic
        // value regardless of any leaked env from the host shell (the per-Pickle plan documents
        // that primary launches must scrub child-mode env to avoid accidentally booting in the
        // wrong role).
        env["PICKY_AGENTD_MODE"] = "primary"
        env["PICKY_AGENTD_PORT"] = String(port)
        env["PICKY_DEFAULT_CWD"] = defaultCwd
        env["PICKY_MAIN_AGENT_CWD"] = mainAgentCwd
        env["PICKY_MAIN_AGENT_THINKING_LEVEL"] = mainAgentThinkingLevel.rawValue
        applyMainAgentModelEnvironment(to: &env)
        applyPickleAgentEnvironment(to: &env)
        env["PICKY_MAIN_AGENT_RUNTIME"] = mainAgentRuntimeMode.agentdEnvironmentValue
        // Scrub any leaked child-only env so a primary never falls into child mode by
        // accident if the user's shell happened to export them.
        env.removeValue(forKey: "PICKY_AGENTD_SESSION_ID")
        env.removeValue(forKey: "PICKY_AGENTD_SESSION_CWD")
        env.removeValue(forKey: "PICKY_AGENTD_PRIMARY_URL")
    }

    private func applyChildEnvironment(to env: inout [String: String], sessionId: String, sessionCwd: String, primaryUrl: String?) {
        env["PICKY_AGENTD_MODE"] = "child"
        env["PICKY_AGENTD_SESSION_ID"] = sessionId
        env["PICKY_AGENTD_SESSION_CWD"] = sessionCwd
        if let primaryUrl {
            env["PICKY_AGENTD_PRIMARY_URL"] = primaryUrl
        } else {
            // Make child env construction deterministic; never inherit a stale primary URL
            // exported from the user shell or a previous run.
            env.removeValue(forKey: "PICKY_AGENTD_PRIMARY_URL")
        }
        applyPickleAgentEnvironment(to: &env)
        // Children always bind on an OS-assigned port; never inherit a primary's pinned port.
        env.removeValue(forKey: "PICKY_AGENTD_PORT")
        // Children do not run main-agent code, so strip the main-agent env so the child
        // bootstrap stays minimal and doesn't accidentally prewarm anything.
        env.removeValue(forKey: "PICKY_DEFAULT_CWD")
        env.removeValue(forKey: "PICKY_MAIN_AGENT_CWD")
        env.removeValue(forKey: "PICKY_MAIN_AGENT_THINKING_LEVEL")
        env.removeValue(forKey: "PICKY_MAIN_AGENT_MODEL")
        env.removeValue(forKey: "PICKY_MAIN_AGENT_RUNTIME")
    }

    private func applyMainAgentModelEnvironment(to env: inout [String: String]) {
        let trimmedMainAgentModel = mainAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMainAgentModel.isEmpty {
            env["PICKY_MAIN_AGENT_MODEL"] = trimmedMainAgentModel
        } else {
            env.removeValue(forKey: "PICKY_MAIN_AGENT_MODEL")
        }
    }

    private func applyPickleAgentEnvironment(to env: inout [String: String]) {
        let trimmedPickleModel = pickleAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPickleModel.isEmpty {
            env["PICKY_PICKLE_MODEL"] = trimmedPickleModel
        } else {
            env.removeValue(forKey: "PICKY_PICKLE_MODEL")
        }
        if let thinkingLevel = pickleAgentThinkingLevel.agentdValue {
            env["PICKY_PICKLE_THINKING_LEVEL"] = thinkingLevel
        } else {
            env.removeValue(forKey: "PICKY_PICKLE_THINKING_LEVEL")
        }
    }

    private static func nodeSource(for resolvedSource: PickyResolvedNodeExecutable.Source) -> PickyNodeSource {
        switch resolvedSource {
        case .override:
            return .override
        case .bundled:
            return .bundled
        }
    }

    static func resolveNodeExecutable(
        bundleResourceURL: URL?,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> PickyResolvedNodeExecutable {
        if let raw = environment["PICKY_NODE_PATH"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
            if isExecutableRegularFile(atPath: url.path, fileManager: fileManager) {
                return .absolute(url, source: .override)
            }
            pickyDaemonLog("PICKY_NODE_PATH=\(raw) is not an executable file; falling back to bundled/PATH lookup.")
        }

        if let resources = bundleResourceURL {
            let bundled = resources
                .appendingPathComponent("agentd-runtime")
                .appendingPathComponent("bin")
                .appendingPathComponent("node")
            if isExecutableRegularFile(atPath: bundled.path, fileManager: fileManager) {
                return .absolute(bundled, source: .bundled)
            }
        }

        return .viaEnv
    }

    /// `FileManager.isExecutableFile(atPath:)` returns true for searchable directories on macOS,
    /// so any directory at the candidate path would be mistakenly accepted as a Node binary.
    /// Require a regular file in addition to the executable bit.
    static func isExecutableRegularFile(atPath path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    static func augmentedExecutablePATH(from environment: [String: String]) -> String {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fallbackPaths = [
            "\(home)/Library/pnpm",
            environment["PNPM_HOME"],
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].compactMap { $0 }

        for path in fallbackPaths where !paths.contains(path) {
            paths.append(path)
        }
        return paths.joined(separator: ":")
    }
}

enum PickyDaemonLifecycleState: Equatable {
    case stopped
    case starting
    case running
    case crashed(exitCode: Int32)
    case restarting(attempt: Int, delay: TimeInterval)
    case failedToStart(String)

    /// Short, log-stable label used for the status snapshot file. Avoids
    /// associated-value churn so a diagnostics reader can grep by name
    /// without parsing the payload.
    var diagnosticsLabel: String {
        switch self {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .crashed: return "crashed"
        case .restarting: return "restarting"
        case .failedToStart: return "failedToStart"
        }
    }
}

/// Snapshot of the daemon launcher's current state. The launcher rewrites a
/// JSON copy of this struct (`agentd.status.json`) on every state transition
/// so the diagnostics bundle can answer "was the daemon even running when the
/// user hit Send Feedback?" without needing a live launcher reference. The
/// file persists across Picky restarts the same way `agentd.stderr.log` does.
struct PickyDaemonStatusSnapshot: Codable, Equatable {
    /// Lifecycle label (matches `PickyDaemonLifecycleState.diagnosticsLabel`).
    var state: String
    /// Optional associated detail for non-trivial states (e.g. exitCode for
    /// `.crashed`, attempt/delay for `.restarting`, error message for
    /// `.failedToStart`). Free-form so the schema does not have to balloon.
    var detail: String?
    /// PID of the agentd child, when one is alive.
    var pid: Int32?
    /// Daemon role: `primary` for the app-wide daemon, `child(sessionId)`
    /// for per-Pickle daemons spawned by the pool.
    var role: String
    /// TCP port the launcher tried to bind. `0` for child daemons that use a
    /// random port.
    var port: Int
    /// Cumulative restart attempts observed by this launcher instance.
    var attempts: Int
    /// ISO-8601 timestamp of the most recent state change.
    var lastUpdatedAt: String
    /// ISO-8601 timestamp of the most recent successful `.running` entry.
    var lastRunningAt: String?
}

enum PickyAgentdRuntimeLocation: Equatable {
    case externalSource(URL)
    case externalCompiled(URL)
    case bundled(URL)
    case missingExternal(URL)
    case missingBundled(URL)
}

struct PickyAgentdRootResolver {
    static func resolveRuntimeLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> PickyAgentdRuntimeLocation {
        if let override = environment["PICKY_AGENTD_ROOT"], !override.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
            if containsSourceAgentdPackage(url, fileManager: fileManager) { return .externalSource(url) }
            if containsCompiledAgentdPackage(url, fileManager: fileManager) { return .externalCompiled(url) }
            return .missingExternal(url)
        }

        let resourceURL = bundleResourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let bundledRoot = resourceURL.appendingPathComponent("agentd", isDirectory: true)
        if containsCompiledAgentdPackage(bundledRoot, fileManager: fileManager) { return .bundled(bundledRoot) }
        return .missingBundled(bundledRoot)
    }

    static func containsAgentdPackage(_ url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("package.json").path)
    }

    static func containsSourceAgentdPackage(_ url: URL, fileManager: FileManager = .default) -> Bool {
        containsAgentdPackage(url, fileManager: fileManager)
            && fileManager.fileExists(atPath: url.appendingPathComponent("src/index.ts").path)
    }

    static func containsCompiledAgentdPackage(_ url: URL, fileManager: FileManager = .default) -> Bool {
        containsAgentdPackage(url, fileManager: fileManager)
            && fileManager.fileExists(atPath: url.appendingPathComponent("dist/index.js").path)
    }
}

enum PickyDaemonLaunchPreflightError: LocalizedError, Equatable {
    case missingAgentdPackage(String)
    case missingAgentdEntryPoint(String)
    case missingRequiredExecutable(String)
    case missingExecutableAtPath(String)

    var errorDescription: String? {
        switch self {
        case .missingAgentdPackage(let message), .missingAgentdEntryPoint(let message), .missingExecutableAtPath(let message):
            message
        case .missingRequiredExecutable(let name):
            "\(name) not found in PATH. Install \(name) or launch Picky with a PATH that includes it."
        }
    }
}

enum PickyExecutableVersionProbeResult: Equatable {
    case version(String)
    case timedOut(seconds: TimeInterval)
    case failed(exitCode: Int32, output: String)
    case emptyOutput
    case launchFailed(String)

    var versionString: String? {
        if case let .version(version) = self { return version }
        return nil
    }

    var diagnosticsStatus: String {
        switch self {
        case .version: return "version"
        case .timedOut: return "timedOut"
        case .failed: return "failed"
        case .emptyOutput: return "emptyOutput"
        case .launchFailed: return "launchFailed"
        }
    }

    var failureReason: String? {
        switch self {
        case .version:
            return nil
        case let .timedOut(seconds):
            return "node --version timed out after \(Self.formatSeconds(seconds))s"
        case let .failed(exitCode, _):
            return "node --version exited with code \(exitCode)"
        case .emptyOutput:
            return "node --version produced no output"
        case let .launchFailed(message):
            return "node --version could not be launched: \(message)"
        }
    }

    var outputPreview: String? {
        switch self {
        case let .failed(_, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(500))
        default:
            return nil
        }
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds { return String(Int(seconds)) }
        return String(format: "%.1f", seconds)
    }
}

struct PickyNodePreflightSnapshot: Codable, Equatable {
    var checkedAt: String
    var command: [String]
    var requiredNodeVersion: String
    var nodePath: String?
    var nodeSource: String?
    var status: String
    var version: String?
    var failureReason: String?
    var exitCode: Int32?
    var timeoutSeconds: TimeInterval?
    var outputPreview: String?
}

protocol PickyProcessRunning: AnyObject {
    var terminationHandler: ((Int32) -> Void)? { get set }
    /// PID of the running child, or `nil` when no process is alive. Used
    /// purely for diagnostics (the launcher writes it into
    /// `agentd.status.json` so a stalled handshake can be correlated with a
    /// concrete agentd process). Test doubles can rely on the default `nil`
    /// implementation below.
    var processIdentifier: Int32? { get }
    func launch(configuration: PickyAgentDaemonConfiguration, stdout: @escaping (Data) -> Void, stderr: @escaping (Data) -> Void) throws
    func terminate()
}

extension PickyProcessRunning {
    var processIdentifier: Int32? { nil }
}

protocol PickyExecutableChecking {
    func executableExists(named name: String, environment: [String: String]) -> Bool
    func executablePath(named name: String, environment: [String: String]) -> String?
    func executableVersion(named name: String, environment: [String: String], workingDirectory: URL) -> String?
    func executableVersionProbe(named name: String, environment: [String: String], workingDirectory: URL) -> PickyExecutableVersionProbeResult
}

extension PickyExecutableChecking {
    func executablePath(named name: String, environment: [String: String]) -> String? { nil }
    func executableVersion(named name: String, environment: [String: String], workingDirectory: URL) -> String? { nil }

    func executableVersionProbe(named name: String, environment: [String: String], workingDirectory: URL) -> PickyExecutableVersionProbeResult {
        guard let version = executableVersion(named: name, environment: environment, workingDirectory: workingDirectory),
              !version.isEmpty else { return .emptyOutput }
        return .version(version)
    }
}

struct PATHPickyExecutableChecker: PickyExecutableChecking {
    private static let versionProbeTimeout: TimeInterval = 5.0

    func executableExists(named name: String, environment: [String: String]) -> Bool {
        executablePath(named: name, environment: environment) != nil
    }

    func executablePath(named name: String, environment: [String: String]) -> String? {
        if name.contains("/") {
            let expanded = NSString(string: name).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let path = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func executableVersion(named name: String, environment: [String: String], workingDirectory: URL) -> String? {
        executableVersionProbe(named: name, environment: environment, workingDirectory: workingDirectory).versionString
    }

    func executableVersionProbe(named name: String, environment: [String: String], workingDirectory: URL) -> PickyExecutableVersionProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [name, "--version"]
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                finished.signal()
            }
            if finished.wait(timeout: .now() + Self.versionProbeTimeout) == .timedOut {
                process.terminate()
                process.waitUntilExit()
                return .timedOut(seconds: Self.versionProbeTimeout)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                return .failed(exitCode: process.terminationStatus, output: output)
            }
            let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty else { return .emptyOutput }
            return .version(version)
        } catch {
            return .launchFailed(error.localizedDescription)
        }
    }
}

final class FoundationPickyProcessRunner: PickyProcessRunning {
    private static let terminationGracePeriod: TimeInterval = 2.0
    private static let terminationPollInterval: TimeInterval = 0.05

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    var terminationHandler: ((Int32) -> Void)?
    var processIdentifier: Int32? { process?.processIdentifier }

    func launch(configuration: PickyAgentDaemonConfiguration, stdout: @escaping (Data) -> Void, stderr: @escaping (Data) -> Void) throws {
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectory
        process.environment = configuration.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in stdout(handle.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in stderr(handle.availableData) }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in self?.terminationHandler?(process.terminationStatus) }

        try process.run()
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func terminate() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        guard let process else {
            stdoutPipe = nil
            stderrPipe = nil
            return
        }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(Self.terminationGracePeriod)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: Self.terminationPollInterval)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        self.process = nil
        stdoutPipe = nil
        stderrPipe = nil
    }
}

@MainActor
final class PickyAgentDaemonLauncher: ObservableObject {
    @Published private(set) var state: PickyDaemonLifecycleState = .stopped

    let configuration: PickyAgentDaemonConfiguration
    private let runner: PickyProcessRunning
    private let logDirectory: URL
    private let fileManager: FileManager
    private let executableChecker: PickyExecutableChecking
    private let stdoutInterceptor: PickyTerminalOutputInterceptor
    private let stdoutLineObserver: ((String) -> Void)?
    // Byte-level buffer so chunks that split mid-UTF-8-codepoint or mid-line do not drop a
    // ready-announce line. We only decode bytes once a full newline-terminated slice arrives.
    private var stdoutLineBufferBytes: [UInt8] = []
    // A pathological child that never emits a newline must not be able to grow the line
    // buffer without bound. Past this many buffered bytes we drop everything currently
    // buffered and synthesize a single `<dropped N bytes>` marker so callers (and the line
    // observer) can see that something went wrong. The cap is generous enough to never
    // affect normal usage (Pi log lines are well under 4 KB).
    private static let stdoutLineBufferLimit = 1_048_576
    /// Size threshold (bytes) at which `agentd.stdout.log` / `agentd.stderr.log`
    /// rotate. Files at or above this size are renamed to `<file>.1` (and the
    /// existing rotated backups shift one step) before the next write. With
    /// the default of 50 MiB and 3 backups, total on-disk cap per stream is
    /// roughly 200 MiB. Override via the init parameter for tests.
    static let defaultMaxLogFileSize: Int64 = 50 * 1024 * 1024
    /// Number of rotated backups to keep alongside the live log file. Set to
    /// 0 to truncate without keeping history.
    static let defaultMaxLogRotations = 3
    /// Files older than this are pruned from `logDirectory` on launcher
    /// start. Targets stale `agentd.status.child-session-*.json` snapshots
    /// that Pickle daemons leave behind when they exit.
    private static let staleStatusFileAge: TimeInterval = 24 * 60 * 60
    private let maxLogFileSize: Int64
    private let maxLogRotations: Int
    /// Cached current size per managed log file so we do not stat the file
    /// on every byte written. Seeded lazily from the on-disk size on the
    /// first append of each file and updated in-place afterwards; reset to 0
    /// when the file is rotated.
    private var logFileSizes: [String: Int64] = [:]
    private var restartTask: Task<Void, Never>?
    private var attempts = 0
    private var intentionallyStopped = false
    private var terminalLaunchFailureMessage: String?
    private var stderrDiagnosticBuffer = ""
    /// Wallclock instant of the most recent `.running` transition. Persisted
    /// into the on-disk status snapshot so diagnostics can spot a daemon that
    /// started successfully but stalled before the handshake.
    private var lastRunningAt: Date?
    /// On-disk path of the status snapshot JSON used by the diagnostics
    /// bundle. Lives alongside `agentd.stderr.log` / `agentd.stdout.log` so
    /// users do not have to opt into anything extra to surface it.
    private static let legacyStatusSnapshotFileName = "agentd.status.json"
    private static let nodePreflightSnapshotFileName = "agentd.node-preflight.json"
    private static let minimumSupportedNodeVersion = "22.19.0"
    private static let unsupportedNodeToken = "PICKY_UNSUPPORTED_NODE"
    private static let stderrDiagnosticBufferLimit = 8_192

    init(
        configuration: PickyAgentDaemonConfiguration,
        runner: PickyProcessRunning = FoundationPickyProcessRunner(),
        logDirectory: URL? = nil,
        fileManager: FileManager = .default,
        executableChecker: PickyExecutableChecking = PATHPickyExecutableChecker(),
        clipboardWriter: PickyClipboardWriting = PickyPasteboardClipboardWriter(),
        stdoutLineObserver: ((String) -> Void)? = nil,
        maxLogFileSize: Int64 = PickyAgentDaemonLauncher.defaultMaxLogFileSize,
        maxLogRotations: Int = PickyAgentDaemonLauncher.defaultMaxLogRotations
    ) {
        self.configuration = configuration
        self.runner = runner
        self.logDirectory = logDirectory ?? configuration.appSupportRoot.appendingPathComponent("Logs", isDirectory: true)
        self.fileManager = fileManager
        self.executableChecker = executableChecker
        self.stdoutInterceptor = PickyTerminalOutputInterceptor(clipboardWriter: clipboardWriter)
        self.stdoutLineObserver = stdoutLineObserver
        self.maxLogFileSize = maxLogFileSize
        self.maxLogRotations = maxLogRotations
        self.runner.terminationHandler = { [weak self] code in
            Task { @MainActor in self?.processTerminated(exitCode: code) }
        }
    }

    func start() {
        guard state == .stopped else { return }
        pickyDaemonLog("start requested port=\(configuration.port) cwd=\(configuration.defaultCwd)")
        intentionallyStopped = false
        terminalLaunchFailureMessage = nil
        stderrDiagnosticBuffer = ""
        purgeStaleChildSessionStatusFiles()
        launch()
    }

    func stop() {
        pickyDaemonLog("stop requested")
        intentionallyStopped = true
        restartTask?.cancel()
        restartTask = nil
        runner.terminate()
        updateState(.stopped)
    }

    private func launch() {
        pickyDaemonLog("launching executable=\(configuration.executableURL.path) args=\(configuration.arguments.joined(separator: " "))")
        updateState(.starting)
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            try preflightConfiguration()
            try runner.launch(
                configuration: configuration,
                stdout: { [weak self] data in self?.appendStdout(data) },
                stderr: { [weak self] data in self?.appendStderr(data) }
            )
            if let terminalLaunchFailureMessage {
                updateState(.failedToStart(terminalLaunchFailureMessage))
                return
            }
            attempts = 0
            lastRunningAt = Date()
            updateState(.running)
            pickyDaemonLog("running pid=\(runner.processIdentifier.map(String.init) ?? "unknown") logDir=\(logDirectory.path)")
        } catch let error as PickyDaemonLaunchPreflightError {
            pickyDaemonLog("preflight failed error=\(error.localizedDescription)")
            updateState(.failedToStart(error.localizedDescription))
        } catch {
            pickyDaemonLog("launch failed error=\(error.localizedDescription)")
            // Child daemons must fail fast (see processTerminated()). A generic launch error
            // in child role surfaces as .failedToStart so the pool's spawn promise rejects;
            // primary daemons keep the historical backoff-restart loop.
            if case .child = configuration.role {
                updateState(.failedToStart(error.localizedDescription))
            } else {
                scheduleRestart(afterExitCode: -1)
            }
        }
    }

    private func preflightConfiguration() throws {
        let packageURL = configuration.workingDirectory.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw PickyDaemonLaunchPreflightError.missingAgentdPackage(
                configuration.missingAgentdPackageMessage
                    ?? "picky-agentd was not found at \(configuration.workingDirectory.path). Set PICKY_AGENTD_ROOT to a local agentd directory or package the bundled daemon."
            )
        }
        if let requiredAgentdEntryPoint = configuration.requiredAgentdEntryPoint {
            let entryPointURL = configuration.workingDirectory.appendingPathComponent(requiredAgentdEntryPoint)
            guard fileManager.fileExists(atPath: entryPointURL.path) else {
                throw PickyDaemonLaunchPreflightError.missingAgentdEntryPoint(
                    configuration.missingAgentdEntryPointMessage
                        ?? "picky-agentd entry point was not found at \(entryPointURL.path)."
                )
            }
        }
        if configuration.executableURL.path != "/usr/bin/env" {
            guard PickyAgentDaemonConfiguration.isExecutableRegularFile(atPath: configuration.executableURL.path, fileManager: fileManager) else {
                throw PickyDaemonLaunchPreflightError.missingExecutableAtPath(missingNodeExecutableMessage())
            }
        } else if let requiredExecutableName = configuration.requiredExecutableName,
                  requiredExecutableName != "node",
                  !executableChecker.executableExists(named: requiredExecutableName, environment: configuration.environment) {
            throw PickyDaemonLaunchPreflightError.missingRequiredExecutable(requiredExecutableName)
        }
        try preflightNodeVersion()
    }

    private func preflightNodeVersion() throws {
        if configuration.executableURL.path != "/usr/bin/env" {
            writeNodePreflightDeferredSnapshot(path: configuration.executableURL.path)
            return
        }

        let env = configuration.environment
        let nodePath = executableChecker.executablePath(named: "node", environment: env)
        guard nodePath != nil || executableChecker.executableExists(named: "node", environment: env) else {
            let message = "node not found in PATH. Install node or launch Picky with a PATH that includes it."
            writeNodePreflightSnapshot(path: nodePath, result: .launchFailed(message))
            throw PickyDaemonLaunchPreflightError.missingRequiredExecutable("node")
        }
        // Do not run a separate `node --version` helper here. On macOS 26 some sandboxed
        // UIElement app contexts can launch short-lived helper processes but fail to observe
        // their exit before the timeout, blocking Pickle child daemon startup. The daemon now
        // validates `process.versions.node` as its first entrypoint step, which is both cheaper
        // and exactly matches the runtime that will execute Pi.
        writeNodePreflightDeferredSnapshot(path: nodePath)
    }

    private func missingNodeExecutableMessage() -> String {
        switch configuration.nodeSource {
        case .override:
            return "PICKY_NODE_PATH=\(configuration.executableURL.path) is not executable. Unset the variable or point it to a Node 22.x binary."
        case .bundled:
            return "Bundled Node at \(configuration.executableURL.path) is missing or not executable. Reinstall Picky."
        case .external, .absent:
            return "Required executable at \(configuration.executableURL.path) is missing or not executable."
        }
    }

    private func processTerminated(exitCode: Int32) {
        guard !intentionallyStopped else { return }
        pickyDaemonLog("terminated exitCode=\(exitCode)")
        if let terminalLaunchFailureMessage {
            pickyDaemonLog("terminal launch failure detected error=\(terminalLaunchFailureMessage)")
            updateState(.failedToStart(terminalLaunchFailureMessage))
            return
        }
        updateState(.crashed(exitCode: exitCode))
        // Per-Pickle child daemons must not auto-restart: the pool resolved an endpoint pinned
        // to the previous port=0 bind, so a fresh restart would come back on a different port
        // that the router doesn't know about. The pool itself surfaces the crash to callers
        // (and Phase 4 can grow an explicit retry policy on top of that).
        if case .child = configuration.role { return }
        scheduleRestart(afterExitCode: exitCode)
    }

    private func scheduleRestart(afterExitCode exitCode: Int32) {
        attempts += 1
        let delay = min(pow(2.0, Double(attempts - 1)), 30.0)
        updateState(.restarting(attempt: attempts, delay: delay))
        pickyDaemonLog("restart scheduled attempt=\(attempts) delay=\(delay)")
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.launch() }
        }
    }

    private func appendStderr(_ data: Data) {
        append(data, to: "agentd.stderr.log")
        guard terminalLaunchFailureMessage == nil,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return }
        stderrDiagnosticBuffer.append(text)
        if stderrDiagnosticBuffer.count > Self.stderrDiagnosticBufferLimit {
            stderrDiagnosticBuffer = String(stderrDiagnosticBuffer.suffix(Self.stderrDiagnosticBufferLimit))
        }
        guard let message = Self.unsupportedNodeFailureMessage(from: stderrDiagnosticBuffer) else { return }
        terminalLaunchFailureMessage = message
        updateState(.failedToStart(message))
    }

    private static func unsupportedNodeFailureMessage(from stderr: String) -> String? {
        for line in stderr.split(whereSeparator: \.isNewline) {
            guard line.contains(Self.unsupportedNodeToken) else { continue }
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            let installed = parts.count > 1 ? String(parts[1]) : "unknown"
            let requiredPart = parts.count > 2 ? String(parts[2]) : "required=\(Self.minimumSupportedNodeVersion)"
            let required = requiredPart.replacingOccurrences(of: "required=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "Node \(installed) is too old for picky-agentd. Install Node \(required.isEmpty ? Self.minimumSupportedNodeVersion : required) or newer and relaunch Picky."
        }
        return nil
    }

    private func appendStdout(_ data: Data) {
        let processed = stdoutInterceptor.process(data)
        append(processed, to: "agentd.stdout.log")
        guard let observer = stdoutLineObserver, !processed.isEmpty else { return }
        // Append raw bytes first so a chunk that ends mid-UTF-8 codepoint does not cause us to
        // drop the buffered prefix. Each line is decoded only once its terminating LF arrives.
        stdoutLineBufferBytes.append(contentsOf: processed)
        if stdoutLineBufferBytes.count > Self.stdoutLineBufferLimit {
            let droppedCount = stdoutLineBufferBytes.count
            stdoutLineBufferBytes.removeAll(keepingCapacity: false)
            observer("<picky-agent-daemon: dropped \(droppedCount) buffered stdout bytes; child emitted no newline>")
            return
        }
        while let newlineIndex = stdoutLineBufferBytes.firstIndex(of: 0x0A) {
            let lineBytes = Array(stdoutLineBufferBytes[..<newlineIndex])
            stdoutLineBufferBytes.removeSubrange(0...newlineIndex)
            // Strip a trailing CR so Windows/CRLF style streams (unlikely from Node but cheap to
            // accommodate) do not break ready-line parsing.
            let trimmed = lineBytes.last == 0x0D ? Array(lineBytes.dropLast()) : lineBytes
            if let line = String(bytes: trimmed, encoding: .utf8) {
                observer(line)
            }
        }
    }

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

    /// Stat the file on the first call (seed the cached size) and rotate when
    /// the live file is at or above `maxLogFileSize`. Backups shift
    /// `<file>.N` -> `<file>.N+1`; the oldest beyond `maxLogRotations` is
    /// removed. The cached size resets to 0 once the live file is rotated
    /// out so the next append starts a fresh count.
    private func rotateLogIfNeeded(url: URL, fileName: String) {
        if logFileSizes[fileName] == nil {
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                logFileSizes[fileName] = size
            } else {
                logFileSizes[fileName] = 0
            }
        }
        guard maxLogFileSize > 0, (logFileSizes[fileName] ?? 0) >= maxLogFileSize else { return }
        let dir = url.deletingLastPathComponent()
        let oldestBackup = dir.appendingPathComponent("\(fileName).\(maxLogRotations)")
        try? fileManager.removeItem(at: oldestBackup)
        if maxLogRotations >= 1 {
            for index in stride(from: maxLogRotations - 1, through: 1, by: -1) {
                let from = dir.appendingPathComponent("\(fileName).\(index)")
                let to = dir.appendingPathComponent("\(fileName).\(index + 1)")
                guard fileManager.fileExists(atPath: from.path) else { continue }
                try? fileManager.removeItem(at: to)
                try? fileManager.moveItem(at: from, to: to)
            }
            let firstBackup = dir.appendingPathComponent("\(fileName).1")
            try? fileManager.removeItem(at: firstBackup)
            try? fileManager.moveItem(at: url, to: firstBackup)
        } else {
            try? fileManager.removeItem(at: url)
        }
        logFileSizes[fileName] = 0
    }

    /// Delete `agentd.status.child-session-*.json` snapshots whose mtime is
    /// older than `staleStatusFileAge`. Pickle daemons write one of these on
    /// every transition and never remove them on exit, so without cleanup
    /// the logs directory grows monotonically across days. Called on every
    /// `start()`; idempotent if nothing matches.
    private func purgeStaleChildSessionStatusFiles() {
        let cutoff = Date().addingTimeInterval(-Self.staleStatusFileAge)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("agentd.status.child-session-") && url.pathExtension == "json" {
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  mtime < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Status snapshot

    /// Updates the in-memory state, publishes it (SwiftUI/Combine observers),
    /// and rewrites the on-disk status snapshot. Centralised so every
    /// transition surfaces in `agentd.status.json` without callers having to
    /// remember.
    private func updateState(_ newState: PickyDaemonLifecycleState) {
        state = newState
        writeStatusSnapshot()
    }

    private func writeStatusSnapshot() {
        let snapshot = PickyDaemonStatusSnapshot(
            state: state.diagnosticsLabel,
            detail: stateDetail(state),
            pid: state == .running ? runner.processIdentifier : nil,
            role: roleLabel,
            port: configuration.port,
            attempts: attempts,
            lastUpdatedAt: Self.iso8601Formatter.string(from: Date()),
            lastRunningAt: lastRunningAt.map(Self.iso8601Formatter.string(from:))
        )
        let urls = statusSnapshotFileNames().map { logDirectory.appendingPathComponent($0) }
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            for url in urls {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Status snapshot is best-effort diagnostics — never fail launch
            // because of it. Log the reason instead so the missing snapshot
            // is itself a breadcrumb.
            pickyDaemonLog("failed to write status snapshot error=\(error.localizedDescription)")
        }
    }

    private func statusSnapshotFileNames() -> [String] {
        [Self.legacyStatusSnapshotFileName, roleSpecificStatusSnapshotFileName()]
    }

    private func roleSpecificStatusSnapshotFileName() -> String {
        switch configuration.role {
        case .primary:
            return "agentd.status.primary.json"
        case let .child(sessionId, _, _):
            let safeId = sessionId
                .map { character in
                    character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
                }
            let prefix = String(String(safeId).prefix(24))
            return "agentd.status.child-\(prefix).json"
        }
    }

    private func writeNodePreflightSnapshot(path: String?, result: PickyExecutableVersionProbeResult) {
        let snapshot = PickyNodePreflightSnapshot(
            checkedAt: Self.iso8601Formatter.string(from: Date()),
            command: ["node", "--version"],
            requiredNodeVersion: Self.minimumSupportedNodeVersion,
            nodePath: path,
            nodeSource: nodeSourceDiagnosticsValue,
            status: result.diagnosticsStatus,
            version: result.versionString,
            failureReason: result.failureReason,
            exitCode: {
                if case let .failed(exitCode, _) = result { return exitCode }
                return nil
            }(),
            timeoutSeconds: {
                if case let .timedOut(seconds) = result { return seconds }
                return nil
            }(),
            outputPreview: result.outputPreview
        )
        writeNodePreflightSnapshot(snapshot)
    }

    private func writeNodePreflightDeferredSnapshot(path: String?) {
        let snapshot = PickyNodePreflightSnapshot(
            checkedAt: Self.iso8601Formatter.string(from: Date()),
            command: configuration.arguments,
            requiredNodeVersion: Self.minimumSupportedNodeVersion,
            nodePath: path,
            nodeSource: nodeSourceDiagnosticsValue,
            status: "deferredToAgentd",
            version: nil,
            failureReason: "Node version is validated by agentd at startup via process.versions.node.",
            exitCode: nil,
            timeoutSeconds: nil,
            outputPreview: nil
        )
        writeNodePreflightSnapshot(snapshot)
    }

    private var nodeSourceDiagnosticsValue: String? {
        configuration.nodeSource == .absent ? nil : configuration.nodeSource.rawValue
    }

    private func writeNodePreflightSnapshot(_ snapshot: PickyNodePreflightSnapshot) {
        let url = logDirectory.appendingPathComponent(Self.nodePreflightSnapshotFileName)
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            pickyDaemonLog("failed to write node preflight snapshot error=\(error.localizedDescription)")
        }
    }

    private var roleLabel: String {
        switch configuration.role {
        case .primary:
            return "primary"
        case let .child(sessionId, _, _):
            // Keep enough of the sessionId to correlate with other log
            // lines from the same Pickle but drop the rest so the status
            // file does not act as a stable per-session beacon if the
            // bundle is shared more widely than intended.
            let prefix = sessionId.prefix(8)
            return "child(\(prefix)…)"
        }
    }

    private func stateDetail(_ state: PickyDaemonLifecycleState) -> String? {
        switch state {
        case .stopped, .starting, .running:
            return nil
        case let .crashed(exitCode):
            return "exitCode=\(exitCode)"
        case let .restarting(attempt, delay):
            return "attempt=\(attempt) delaySeconds=\(delay)"
        case let .failedToStart(message):
            return message
        }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        return formatter
    }()
}

private final class PickyTerminalOutputInterceptor {
    private static let escapeByte: UInt8 = 0x1B
    private static let oscByte: UInt8 = 0x5D
    private static let belByte: UInt8 = 0x07
    private static let stByte: UInt8 = 0x5C
    private static let maxBufferedOSCBytes = 2_000_000
    private static let maxOSC52PayloadBytes = 1_000_000

    private let clipboardWriter: PickyClipboardWriting
    private var bufferedBytes: [UInt8] = []

    init(clipboardWriter: PickyClipboardWriting) {
        self.clipboardWriter = clipboardWriter
    }

    func process(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        bufferedBytes.append(contentsOf: data)

        var output: [UInt8] = []
        var cursor = 0

        while cursor < bufferedBytes.count {
            guard let oscStart = findOSCStart(from: cursor) else {
                if bufferedBytes.last == Self.escapeByte {
                    if cursor < bufferedBytes.count - 1 {
                        output.append(contentsOf: bufferedBytes[cursor..<(bufferedBytes.count - 1)])
                    }
                    bufferedBytes = [Self.escapeByte]
                    return Data(output)
                }
                output.append(contentsOf: bufferedBytes[cursor...])
                bufferedBytes.removeAll(keepingCapacity: true)
                return Data(output)
            }

            if oscStart > cursor {
                output.append(contentsOf: bufferedBytes[cursor..<oscStart])
            }

            guard let terminator = findOSCTerminator(from: oscStart + 2) else {
                if bufferedBytes.count - oscStart > Self.maxBufferedOSCBytes {
                    output.append(contentsOf: Array("[Picky dropped unterminated terminal OSC sequence]\n".utf8))
                    bufferedBytes.removeAll(keepingCapacity: true)
                    return Data(output)
                }
                bufferedBytes = Array(bufferedBytes[oscStart...])
                return Data(output)
            }

            let body = Array(bufferedBytes[(oscStart + 2)..<terminator.start])
            output.append(contentsOf: Array(replacementText(forOSCBody: body).utf8))
            cursor = terminator.end
        }

        bufferedBytes.removeAll(keepingCapacity: true)
        return Data(output)
    }

    private func findOSCStart(from start: Int) -> Int? {
        guard start < bufferedBytes.count else { return nil }
        var index = start
        while index + 1 < bufferedBytes.count {
            if bufferedBytes[index] == Self.escapeByte && bufferedBytes[index + 1] == Self.oscByte { return index }
            index += 1
        }
        return nil
    }

    private func findOSCTerminator(from start: Int) -> (start: Int, end: Int)? {
        guard start < bufferedBytes.count else { return nil }
        var index = start
        while index < bufferedBytes.count {
            if bufferedBytes[index] == Self.belByte { return (index, index + 1) }
            if index + 1 < bufferedBytes.count,
               bufferedBytes[index] == Self.escapeByte,
               bufferedBytes[index + 1] == Self.stByte {
                return (index, index + 2)
            }
            index += 1
        }
        return nil
    }

    private func replacementText(forOSCBody body: [UInt8]) -> String {
        guard let text = String(bytes: body, encoding: .utf8) else {
            return "[Picky stripped terminal OSC sequence]\n"
        }

        if text.hasPrefix("52;") {
            return handleOSC52(text)
        }

        let command = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "unknown"
        return "[Picky stripped terminal OSC sequence: OSC \(command)]\n"
    }

    private func handleOSC52(_ body: String) -> String {
        let parts = body.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return "[Picky ignored malformed OSC52 clipboard request]\n"
        }

        let payload = String(parts[2])
        guard payload.utf8.count <= Self.maxOSC52PayloadBytes else {
            return "[Picky ignored oversized OSC52 clipboard request: \(payload.utf8.count) bytes]\n"
        }

        guard let decoded = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              let clipboardText = String(data: decoded, encoding: .utf8) else {
            return "[Picky ignored invalid OSC52 clipboard request]\n"
        }

        clipboardWriter.copy(clipboardText)
        return "[Picky intercepted OSC52 clipboard request: \(clipboardText.count) chars]\n"
    }
}

private func pickyDaemonLog(_ message: String) {
    PickyLog.notice(.daemonLauncher, prefix: "🛠️ Picky agentd launcher —", message: message)
}
