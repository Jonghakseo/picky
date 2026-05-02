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
    var runtime: String?
    var workingDirectory: URL
    var executableURL: URL
    var arguments: [String]
    var requiredExecutableName: String? = nil

    static func development(
        port: Int = 17631,
        token: String = UUID().uuidString,
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        defaultCwd: String = FileManager.default.homeDirectoryForCurrentUser.path,
        filePath: String = #filePath
    ) -> PickyAgentDaemonConfiguration {
        let agentdRoot = PickyAgentdRootResolver.resolveDevelopmentAgentdRoot(filePath: filePath)
        return PickyAgentDaemonConfiguration(
            port: port,
            token: token,
            appSupportRoot: appSupportRoot,
            defaultCwd: defaultCwd,
            runtime: ProcessInfo.processInfo.environment["PICKY_AGENTD_RUNTIME"],
            workingDirectory: agentdRoot,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["pnpm", "--dir", agentdRoot.path, "exec", "tsx", "src/index.ts"],
            requiredExecutableName: "pnpm"
        )
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.augmentedExecutablePATH(from: env)
        env["PICKY_AGENTD_PORT"] = String(port)
        env["PICKY_AGENTD_TOKEN"] = token
        env["PICKY_APP_SUPPORT_DIR"] = appSupportRoot.path
        env["PICKY_DEFAULT_CWD"] = defaultCwd
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

struct PickyAgentdRootResolver {
    static func resolveDevelopmentAgentdRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        filePath: String = #filePath,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["PICKY_AGENTD_ROOT"] {
            let url = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
            if containsAgentdPackage(url, fileManager: fileManager) { return url }
        }

        if let found = searchUpwardForAgentd(from: currentDirectory, fileManager: fileManager) { return found }
        let sourceURL = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        if let found = searchUpwardForAgentd(from: sourceURL, fileManager: fileManager) { return found }
        if let resourceURL = bundleResourceURL?.appendingPathComponent("agentd", isDirectory: true), containsAgentdPackage(resourceURL, fileManager: fileManager) { return resourceURL }
        return currentDirectory.appendingPathComponent("agentd", isDirectory: true)
    }

    static func containsAgentdPackage(_ url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("package.json").path)
    }

    private static func searchUpwardForAgentd(from start: URL, fileManager: FileManager) -> URL? {
        var candidate = start.standardizedFileURL
        while true {
            let agentd = candidate.appendingPathComponent("agentd", isDirectory: true)
            if containsAgentdPackage(agentd, fileManager: fileManager) { return agentd }
            if candidate.path == "/" { return nil }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }
}

enum PickyDaemonLaunchPreflightError: LocalizedError, Equatable {
    case missingAgentdPackage(String)
    case missingRequiredExecutable(String)

    var errorDescription: String? {
        switch self {
        case .missingAgentdPackage(let path):
            "picky-agentd was not found at \(path). Set PICKY_AGENTD_ROOT to the local agentd directory or install the bundled daemon."
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
            throw PickyDaemonLaunchPreflightError.missingAgentdPackage(configuration.workingDirectory.path)
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
