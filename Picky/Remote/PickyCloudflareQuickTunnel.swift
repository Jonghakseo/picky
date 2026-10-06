//
//  PickyCloudflareQuickTunnel.swift
//  Picky
//
//  Runs the user's own `cloudflared` as a Quick Tunnel in front of the remote
//  gateway, for the Cloudflare entrance's "temporary address" mode. Cloudflare
//  hands out a random `https://<words>.trycloudflare.com` address each time
//  the tunnel starts; nothing here can keep it stable, which is why the
//  settings page tells the user to pair the phone again after a change.
//
//  Quick Tunnels are documented as a testing feature with no uptime guarantee
//  (https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/).
//

import Darwin
import Foundation

enum PickyQuickTunnelState: Equatable {
    case stopped
    /// `cloudflared` is running but has not printed its address or registered
    /// a connection with the edge yet.
    case starting
    case running(url: String)
    /// The last run ended; a restart is scheduled unless the user turned the
    /// entrance off. The reason is `cloudflared`'s own error line.
    case failed(String)
    /// No `cloudflared` binary where Homebrew installs it.
    case notInstalled

    var url: String? {
        if case .running(let url) = self { return url }
        return nil
    }
}

/// The tunnel as the controller uses it, so tests never spawn `cloudflared`.
@MainActor
protocol PickyQuickTunnelControlling: AnyObject {
    var state: PickyQuickTunnelState { get }
    var onStateChange: ((PickyQuickTunnelState) -> Void)? { get set }
    /// Idempotent for the same port: a running tunnel keeps its address.
    func start(port: Int)
    func stop()
    func stopAndWaitForExit()
}

enum PickyCloudflaredCLI {
    static let candidatePaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
    ]

    static func locate(fileManager: FileManager = .default) -> URL? {
        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func arguments(port: Int) -> [String] {
        // `--no-autoupdate`: an update would restart the process and change the
        // address under a paired phone.
        // `--protocol http2`: without the flag a Quick Tunnel pins QUIC and never
        // falls back, so a network that drops UDP 7844 leaves it retrying
        // forever with no address. `auto` does fall back, but only after about
        // two and a half minutes of failed QUIC dials. HTTP/2 over TCP works
        // on those networks and only covers the Mac-to-Cloudflare hop.
        ["tunnel", "--no-autoupdate", "--protocol", "http2", "--url", "http://127.0.0.1:\(port)"]
    }
}

/// Reads `cloudflared`'s log lines. It logs to stderr, one event per line:
///   `INF |  https://argued-libraries-affiliate-distance.trycloudflare.com  |`
///   `INF Registered tunnel connection connIndex=0 ...`
///   `ERR failed to request quick Tunnel: ...`
enum PickyQuickTunnelLogParser {
    static func publicURL(in line: String) -> String? {
        guard let range = line.range(
            of: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return line[range].lowercased()
    }

    static func registersConnection(_ line: String) -> Bool {
        line.contains("Registered tunnel connection")
    }

    /// Cloudflare deleted this Quick Tunnel, typically after the Mac was
    /// offline or asleep for a while. `cloudflared` keeps retrying the dead
    /// tunnel forever without exiting, and its address no longer resolves, so
    /// only a fresh run (with a new address) brings the phone back.
    ///   `ERR Register tunnel error from server side error="Unauthorized: Tunnel not found" ...`
    static func reportsTunnelGone(_ line: String) -> Bool {
        line.contains(" ERR ") && line.contains("Tunnel not found")
    }

    /// The message part of an `ERR` line, without the timestamp and level.
    /// The origin certificate warning is ignored: a Quick Tunnel needs no
    /// certificate, and `cloudflared` prints it on every start.
    static func errorMessage(in line: String) -> String? {
        guard let range = line.range(of: " ERR ") else { return nil }
        let message = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty, !message.contains("origin certificate") else { return nil }
        return message
    }
}

/// A `cloudflared` left behind by a crashed Picky keeps forwarding to the
/// gateway port. The pid file lets the next launch find and stop it, and the
/// executable path check keeps a recycled pid from killing something else.
struct PickyQuickTunnelPidFile {
    let url: URL

    func write(_ pid: Int32) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(pid)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns the pid it stopped, if any.
    @discardableResult
    func stopLeftover() -> Int32? {
        defer { remove() }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              Self.executablePath(of: pid)?.hasSuffix("/cloudflared") == true
        else { return nil }
        Darwin.kill(pid, SIGTERM)
        return pid
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

@MainActor
final class PickyCloudflareQuickTunnel: PickyQuickTunnelControlling {
    private static let restartBackoffSeconds: [TimeInterval] = [2, 5, 10, 30]
    private static let maxLogFileSize: Int64 = 2 * 1024 * 1024
    static let logFileName = "cloudflared.log"

    private(set) var state: PickyQuickTunnelState = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((PickyQuickTunnelState) -> Void)?

    private let locateExecutable: () -> URL?
    private let logURL: URL
    private let pidFile: PickyQuickTunnelPidFile
    private var process: Process?
    private var stderrPipe: Pipe?
    private var stderrBuffer: [UInt8] = []
    private var desiredPort: Int?
    private var launchGeneration = 0
    private var restartTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var pendingURL: String?
    private var lastError: String?

    init(
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        locateExecutable: @escaping () -> URL? = { PickyCloudflaredCLI.locate() }
    ) {
        self.locateExecutable = locateExecutable
        self.logURL = appSupportRoot
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(Self.logFileName)
        self.pidFile = PickyQuickTunnelPidFile(
            url: appSupportRoot
                .appendingPathComponent("Remote", isDirectory: true)
                .appendingPathComponent("cloudflared.pid")
        )
    }

    func start(port: Int) {
        if desiredPort == port, state != .stopped, state != .notInstalled { return }
        desiredPort = port
        consecutiveFailures = 0
        launch()
    }

    func stop() {
        shutdown(waitForExit: false)
    }

    func stopAndWaitForExit() {
        shutdown(waitForExit: true)
    }

    private func shutdown(waitForExit: Bool) {
        desiredPort = nil
        restartTask?.cancel()
        restartTask = nil
        launchGeneration &+= 1
        terminateProcess(waitForExit: waitForExit)
        pidFile.remove()
        state = .stopped
    }

    private func terminateProcess(waitForExit: Bool = false) {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        let running = process
        process = nil
        guard let running, running.isRunning else { return }
        running.terminationHandler = nil
        running.terminate()
        if waitForExit {
            Self.escalateTermination(of: running)
        } else {
            DispatchQueue.global(qos: .utility).async { Self.escalateTermination(of: running) }
        }
    }

    nonisolated private static func escalateTermination(of process: Process) {
        guard PickyRemoteGatewayTermination.needsKillAfterGracePeriod(isRunning: { process.isRunning }) else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    private func launch() {
        guard let port = desiredPort else { return }
        terminateProcess()
        pidFile.stopLeftover()
        stderrBuffer.removeAll(keepingCapacity: true)
        pendingURL = nil
        lastError = nil

        guard let executable = locateExecutable() else {
            // Not retried on a timer: installing it is a user action, and the
            // settings page offers "check again", which calls `start` anew.
            desiredPort = nil
            state = .notInstalled
            return
        }
        state = .starting

        let process = Process()
        process.executableURL = executable
        process.arguments = PickyCloudflaredCLI.arguments(port: port)
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        launchGeneration &+= 1
        let generation = launchGeneration
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.handleStderr(data, generation: generation) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in self?.handleExit(status: status, generation: generation) }
        }
        self.stderrPipe = stderrPipe

        do {
            try process.run()
            self.process = process
            pidFile.write(process.processIdentifier)
        } catch {
            self.process = nil
            state = .failed(error.localizedDescription)
            scheduleRestart()
        }
    }

    private func handleStderr(_ data: Data, generation: Int) {
        appendLog(data)
        guard generation == launchGeneration else { return }
        stderrBuffer.append(contentsOf: data)
        // `handle(line:)` may relaunch, which bumps the generation; lines
        // still buffered belong to the abandoned run.
        while generation == launchGeneration, let newlineIndex = stderrBuffer.firstIndex(of: 0x0A) {
            let lineBytes = Array(stderrBuffer[..<newlineIndex])
            stderrBuffer.removeSubrange(0...newlineIndex)
            guard let line = String(bytes: lineBytes, encoding: .utf8) else { continue }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        if let url = PickyQuickTunnelLogParser.publicURL(in: line) {
            pendingURL = url
        }
        if let message = PickyQuickTunnelLogParser.errorMessage(in: line) {
            lastError = message
        }
        if PickyQuickTunnelLogParser.reportsTunnelGone(line) {
            abandonDeadTunnel()
            return
        }
        // The address is printed before the edge accepts the connection;
        // a phone opening it in between gets Cloudflare's error page.
        if PickyQuickTunnelLogParser.registersConnection(line), let url = pendingURL {
            consecutiveFailures = 0
            state = .running(url: url)
        }
    }

    private func handleExit(status: Int32, generation: Int) {
        guard generation == launchGeneration else { return }
        process = nil
        pidFile.remove()
        guard desiredPort != nil else {
            state = .stopped
            return
        }
        state = .failed(lastError ?? L10n.t("settings.remote.cloudflare.quick.error.exited", String(status)))
        scheduleRestart()
    }

    private func abandonDeadTunnel() {
        launchGeneration &+= 1
        terminateProcess()
        pidFile.remove()
        stderrBuffer.removeAll(keepingCapacity: true)
        state = .failed(lastError ?? L10n.t("settings.remote.cloudflare.quick.error.exited", "1"))
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

    private func appendLog(_ data: Data) {
        let manager = FileManager.default
        try? manager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber,
           size.int64Value >= Self.maxLogFileSize {
            let backup = logURL.appendingPathExtension("1")
            try? manager.removeItem(at: backup)
            try? manager.moveItem(at: logURL, to: backup)
        }
        if !manager.fileExists(atPath: logURL.path) {
            manager.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
