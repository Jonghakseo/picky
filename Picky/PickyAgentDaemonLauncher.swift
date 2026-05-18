//
//  PickyAgentDaemonLauncher.swift
//  Picky
//
//  Child-process supervisor for local picky-agentd.
//

import Combine
import Foundation

enum PickyAgentDaemonRole: Equatable {
    case primary
    /// Per-Pickle child daemon (Phase 2 of the per-Pickle agentd plan). Hosts a single Pickle
    /// session keyed by sessionId, binds on a random port (env PICKY_AGENTD_PORT is omitted), and
    /// uses sessionCwd as the workspace cwd so `pi-extension-claude-mcp-bridge` walks up from
    /// the correct directory. `primaryUrl` is reserved for Phase 3 RPC mirroring.
    case child(sessionId: String, sessionCwd: String, primaryUrl: String?)
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
    var runtime: String?
    var workingDirectory: URL
    var executableURL: URL
    var arguments: [String]
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
            runtime: environment["PICKY_AGENTD_RUNTIME"]
            // Intentionally do not stash `environment` as baseEnvironment for primary mode:
            // the lazy daemonConfiguration in PickyApp.swift is built once at app launch, and
            // capturing the env dictionary here would freeze the launcher's environment view
            // to the app-start snapshot. Leave baseEnvironment nil so the getter keeps reading
            // ProcessInfo.processInfo.environment on every launch, matching pre-Phase-2
            // behaviour. Tests that need a deterministic env can set baseEnvironment directly
            // on the returned configuration before reading `environment`.
        )
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
        runtime: String?,
        baseEnvironment: [String: String]? = nil
    ) -> PickyAgentDaemonConfiguration {
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
                    runtime: runtime,
                workingDirectory: root,
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["node", entryPoint],
                requiredExecutableName: "node",
                requiredAgentdEntryPoint: "dist/index.js"
            )
            config.baseEnvironment = baseEnvironment
            return config
        case .missingExternal(let root):
            let message = "PICKY_AGENTD_ROOT does not contain a runnable picky-agentd package at \(root.path). Expected src/index.ts for development or dist/index.js for a compiled runtime."
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
                    runtime: runtime,
                workingDirectory: root,
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["node", root.appendingPathComponent("dist/index.js").path],
                requiredExecutableName: "node",
                requiredAgentdEntryPoint: "dist/index.js",
                missingAgentdPackageMessage: message,
                missingAgentdEntryPointMessage: message
            )
            config.baseEnvironment = baseEnvironment
            return config
        case .missingBundled(let root):
            let message = "Bundled picky-agentd was not found in app resources at \(root.path). Package Picky with scripts/package-signed-app.sh or set PICKY_AGENTD_ROOT to a local agentd directory."
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
                    runtime: runtime,
                workingDirectory: root,
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["node", root.appendingPathComponent("dist/index.js").path],
                requiredExecutableName: "node",
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
            runtime: environment["PICKY_AGENTD_RUNTIME"]
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
        env["PICKY_APP_SUPPORT_DIR"] = appSupportRoot.path
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
    case nodeVersionProbeFailed(reason: String, required: String)
    case unsupportedNodeVersion(installed: String, required: String)

    var errorDescription: String? {
        switch self {
        case .missingAgentdPackage(let message), .missingAgentdEntryPoint(let message):
            message
        case .missingRequiredExecutable(let name):
            "\(name) not found in PATH. Install \(name) or launch Picky with a PATH that includes it."
        case .nodeVersionProbeFailed(let reason, let required):
            "Node.js \(required) or newer is required by Pi, but Picky could not verify the current node version (\(reason)). Update Node or launch Picky with a PATH that points to a working Node executable."
        case .unsupportedNodeVersion(let installed, let required):
            "Node.js \(required) or newer is required by Pi. Current node version is \(installed). Update Node or launch Picky with a PATH that points to a newer node."
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
        process?.terminate()
        process = nil
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
    private var restartTask: Task<Void, Never>?
    private var attempts = 0
    private var intentionallyStopped = false
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

    init(
        configuration: PickyAgentDaemonConfiguration,
        runner: PickyProcessRunning = FoundationPickyProcessRunner(),
        logDirectory: URL? = nil,
        fileManager: FileManager = .default,
        executableChecker: PickyExecutableChecking = PATHPickyExecutableChecker(),
        clipboardWriter: PickyClipboardWriting = PickyPasteboardClipboardWriter(),
        stdoutLineObserver: ((String) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.runner = runner
        self.logDirectory = logDirectory ?? configuration.appSupportRoot.appendingPathComponent("Logs", isDirectory: true)
        self.fileManager = fileManager
        self.executableChecker = executableChecker
        self.stdoutInterceptor = PickyTerminalOutputInterceptor(clipboardWriter: clipboardWriter)
        self.stdoutLineObserver = stdoutLineObserver
        self.runner.terminationHandler = { [weak self] code in
            Task { @MainActor in self?.processTerminated(exitCode: code) }
        }
    }

    func start() {
        guard state == .stopped else { return }
        pickyDaemonLog("start requested port=\(configuration.port) cwd=\(configuration.defaultCwd)")
        intentionallyStopped = false
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
                stderr: { [weak self] data in self?.append(data, to: "agentd.stderr.log") }
            )
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
        if let requiredExecutableName = configuration.requiredExecutableName,
           requiredExecutableName != "node",
           !executableChecker.executableExists(named: requiredExecutableName, environment: configuration.environment) {
            throw PickyDaemonLaunchPreflightError.missingRequiredExecutable(requiredExecutableName)
        }
        try preflightNodeVersion()
    }

    private func preflightNodeVersion() throws {
        let env = configuration.environment
        let nodePath = executableChecker.executablePath(named: "node", environment: env)
        guard executableChecker.executableExists(named: "node", environment: env) else {
            writeNodePreflightSnapshot(path: nodePath, result: .launchFailed("node not found in PATH"))
            throw PickyDaemonLaunchPreflightError.missingRequiredExecutable("node")
        }
        let result = executableChecker.executableVersionProbe(named: "node", environment: env, workingDirectory: configuration.workingDirectory)
        writeNodePreflightSnapshot(path: nodePath, result: result)
        guard let installed = result.versionString else {
            throw PickyDaemonLaunchPreflightError.nodeVersionProbeFailed(
                reason: result.failureReason ?? "unknown probe failure",
                required: Self.minimumSupportedNodeVersion
            )
        }
        guard Self.isVersion(installed, atLeast: Self.minimumSupportedNodeVersion) else {
            throw PickyDaemonLaunchPreflightError.unsupportedNodeVersion(
                installed: installed,
                required: Self.minimumSupportedNodeVersion
            )
        }
    }

    private static func isVersion(_ candidate: String, atLeast required: String) -> Bool {
        let candidateParts = semanticVersionParts(candidate)
        let requiredParts = semanticVersionParts(required)
        for index in 0..<max(candidateParts.count, requiredParts.count) {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < requiredParts.count ? requiredParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    private static func semanticVersionParts(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return trimmed.split(separator: ".").map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }

    private func processTerminated(exitCode: Int32) {
        guard !intentionallyStopped else { return }
        pickyDaemonLog("terminated exitCode=\(exitCode)")
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
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
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
