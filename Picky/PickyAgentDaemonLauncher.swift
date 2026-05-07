//
//  PickyAgentDaemonLauncher.swift
//  Picky
//
//  Child-process supervisor for local picky-agentd.
//

import Combine
import Foundation

struct PickyAgentDaemonConfiguration: Equatable {
    var port: Int
    var token: String
    var appSupportRoot: URL
    var defaultCwd: String
    var mainAgentThinkingLevel: PickyMainAgentThinkingLevel = .medium
    var runtime: String?
    var workingDirectory: URL
    var executableURL: URL
    var arguments: [String]
    var requiredExecutableName: String? = nil
    var requiredAgentdEntryPoint: String? = nil
    var missingAgentdPackageMessage: String? = nil
    var missingAgentdEntryPointMessage: String? = nil

    static func development(
        port: Int = 17631,
        token: String = UUID().uuidString,
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        defaultCwd: String = FileManager.default.homeDirectoryForCurrentUser.path,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel = .medium,
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
            mainAgentThinkingLevel: mainAgentThinkingLevel,
            runtime: environment["PICKY_AGENTD_RUNTIME"]
        )
    }

    private static func configuration(
        for location: PickyAgentdRuntimeLocation,
        port: Int,
        token: String,
        appSupportRoot: URL,
        defaultCwd: String,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel,
        runtime: String?
    ) -> PickyAgentDaemonConfiguration {
        switch location {
        case .externalSource(let root):
            return PickyAgentDaemonConfiguration(
                port: port,
                token: token,
                appSupportRoot: appSupportRoot,
                defaultCwd: defaultCwd,
                mainAgentThinkingLevel: mainAgentThinkingLevel,
                runtime: runtime,
                workingDirectory: root,
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["pnpm", "--dir", root.path, "exec", "tsx", "src/index.ts"],
                requiredExecutableName: "pnpm",
                requiredAgentdEntryPoint: "src/index.ts"
            )
        case .externalCompiled(let root), .bundled(let root):
            let entryPoint = root.appendingPathComponent("dist/index.js").path
            return PickyAgentDaemonConfiguration(
                port: port,
                token: token,
                appSupportRoot: appSupportRoot,
                defaultCwd: defaultCwd,
                mainAgentThinkingLevel: mainAgentThinkingLevel,
                runtime: runtime,
                workingDirectory: root,
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["node", entryPoint],
                requiredExecutableName: "node",
                requiredAgentdEntryPoint: "dist/index.js"
            )
        case .missingExternal(let root):
            let message = "PICKY_AGENTD_ROOT does not contain a runnable picky-agentd package at \(root.path). Expected src/index.ts for development or dist/index.js for a compiled runtime."
            return PickyAgentDaemonConfiguration(
                port: port,
                token: token,
                appSupportRoot: appSupportRoot,
                defaultCwd: defaultCwd,
                mainAgentThinkingLevel: mainAgentThinkingLevel,
                runtime: runtime,
                workingDirectory: root,
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["node", root.appendingPathComponent("dist/index.js").path],
                requiredExecutableName: "node",
                requiredAgentdEntryPoint: "dist/index.js",
                missingAgentdPackageMessage: message,
                missingAgentdEntryPointMessage: message
            )
        case .missingBundled(let root):
            let message = "Bundled picky-agentd was not found in app resources at \(root.path). Package Picky with scripts/package-signed-app.sh or set PICKY_AGENTD_ROOT to a local agentd directory."
            return PickyAgentDaemonConfiguration(
                port: port,
                token: token,
                appSupportRoot: appSupportRoot,
                defaultCwd: defaultCwd,
                mainAgentThinkingLevel: mainAgentThinkingLevel,
                runtime: runtime,
                workingDirectory: root,
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["node", root.appendingPathComponent("dist/index.js").path],
                requiredExecutableName: "node",
                requiredAgentdEntryPoint: "dist/index.js",
                missingAgentdPackageMessage: message,
                missingAgentdEntryPointMessage: message
            )
        }
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.augmentedExecutablePATH(from: env)
        env["PICKY_AGENTD_PORT"] = String(port)
        env["PICKY_AGENTD_TOKEN"] = token
        env["PICKY_APP_SUPPORT_DIR"] = appSupportRoot.path
        env["PICKY_DEFAULT_CWD"] = defaultCwd
        env["PICKY_MAIN_AGENT_THINKING_LEVEL"] = mainAgentThinkingLevel.rawValue
        if let runtime { env["PICKY_AGENTD_RUNTIME"] = runtime }
        return env
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

    var errorDescription: String? {
        switch self {
        case .missingAgentdPackage(let message), .missingAgentdEntryPoint(let message):
            message
        case .missingRequiredExecutable(let name):
            "\(name) not found in PATH. Install \(name) or launch Picky with a PATH that includes it."
        }
    }
}

protocol PickyProcessRunning: AnyObject {
    var terminationHandler: ((Int32) -> Void)? { get set }
    func launch(configuration: PickyAgentDaemonConfiguration, stdout: @escaping (Data) -> Void, stderr: @escaping (Data) -> Void) throws
    func terminate()
}

protocol PickyExecutableChecking {
    func executableExists(named name: String, environment: [String: String]) -> Bool
}

struct PATHPickyExecutableChecker: PickyExecutableChecking {
    func executableExists(named name: String, environment: [String: String]) -> Bool {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: NSString(string: name).expandingTildeInPath)
        }
        let path = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path)
        }
    }
}

final class FoundationPickyProcessRunner: PickyProcessRunning {
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    var terminationHandler: ((Int32) -> Void)?

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

    private let configuration: PickyAgentDaemonConfiguration
    private let runner: PickyProcessRunning
    private let logDirectory: URL
    private let fileManager: FileManager
    private let executableChecker: PickyExecutableChecking
    private var restartTask: Task<Void, Never>?
    private var attempts = 0
    private var intentionallyStopped = false

    init(
        configuration: PickyAgentDaemonConfiguration,
        runner: PickyProcessRunning = FoundationPickyProcessRunner(),
        logDirectory: URL? = nil,
        fileManager: FileManager = .default,
        executableChecker: PickyExecutableChecking = PATHPickyExecutableChecker()
    ) {
        self.configuration = configuration
        self.runner = runner
        self.logDirectory = logDirectory ?? configuration.appSupportRoot.appendingPathComponent("Logs", isDirectory: true)
        self.fileManager = fileManager
        self.executableChecker = executableChecker
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
        state = .stopped
    }

    private func launch() {
        pickyDaemonLog("launching executable=\(configuration.executableURL.path) args=\(configuration.arguments.joined(separator: " "))")
        state = .starting
        do {
            try preflightConfiguration()
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            try runner.launch(
                configuration: configuration,
                stdout: { [weak self] data in self?.append(data, to: "agentd.stdout.log") },
                stderr: { [weak self] data in self?.append(data, to: "agentd.stderr.log") }
            )
            attempts = 0
            state = .running
            pickyDaemonLog("running logDir=\(logDirectory.path)")
        } catch let error as PickyDaemonLaunchPreflightError {
            pickyDaemonLog("preflight failed error=\(error.localizedDescription)")
            state = .failedToStart(error.localizedDescription)
        } catch {
            pickyDaemonLog("launch failed error=\(error.localizedDescription)")
            scheduleRestart(afterExitCode: -1)
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
           !executableChecker.executableExists(named: requiredExecutableName, environment: configuration.environment) {
            throw PickyDaemonLaunchPreflightError.missingRequiredExecutable(requiredExecutableName)
        }
    }

    private func processTerminated(exitCode: Int32) {
        guard !intentionallyStopped else { return }
        pickyDaemonLog("terminated exitCode=\(exitCode)")
        state = .crashed(exitCode: exitCode)
        scheduleRestart(afterExitCode: exitCode)
    }

    private func scheduleRestart(afterExitCode exitCode: Int32) {
        attempts += 1
        let delay = min(pow(2.0, Double(attempts - 1)), 30.0)
        state = .restarting(attempt: attempts, delay: delay)
        pickyDaemonLog("restart scheduled attempt=\(attempts) delay=\(delay)")
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.launch() }
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
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

private func pickyDaemonLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    print("🛠️ Picky agentd launcher — \(message)")
}
