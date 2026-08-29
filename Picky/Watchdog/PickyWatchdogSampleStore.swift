//
//  PickyWatchdogSampleStore.swift
//  Picky
//
//  Captures `/usr/bin/sample` snapshots of the main process when the
//  watchdog detects a spin, and rotates the resulting files so the log
//  directory does not grow unbounded.
//

import Foundation
import os

final class PickyWatchdogSampleStore {
    /// Abstracts the actual `/usr/bin/sample` invocation so tests can inject
    /// a fake runner without spawning a real process.
    protocol ProcessRunner {
        func runSample(pid: Int32, duration: Int, outputPath: URL) throws
    }

    struct DefaultProcessRunner: ProcessRunner {
        func runSample(pid: Int32, duration: Int, outputPath: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [
                String(pid),
                String(duration),
                "-mayDie",
                "-file", outputPath.path,
            ]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(
                    domain: "PickyWatchdogSampleStore",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "sample exited with status \(process.terminationStatus)"]
                )
            }
        }
    }

    private let directory: URL
    private let runner: ProcessRunner
    private let clock: () -> Date
    private let fileManager: FileManager
    private let systemLoad: () -> PickyWatchdogSystemLoad
    private let log = Logger(subsystem: "com.jonghakseo.picky", category: "watchdog.sample")

    /// Reports current main-thread heartbeat staleness. Read after `sample`
    /// exits so the header can state whether the stall outlasted the capture
    /// or recovered midway. Assigned after construction because the watchdog
    /// that answers it is built later.
    var heartbeatAgeProvider: () -> TimeInterval? = { nil }

    init(
        directory: URL,
        runner: ProcessRunner = DefaultProcessRunner(),
        clock: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        systemLoad: @escaping () -> PickyWatchdogSystemLoad = PickyWatchdogSystemLoad.current
    ) {
        self.directory = directory
        self.runner = runner
        self.clock = clock
        self.fileManager = fileManager
        self.systemLoad = systemLoad
    }

    /// Runs `sample` against the given pid for `duration` seconds and writes
    /// the result to a timestamped `spin-*.txt` file in the configured
    /// directory, prefixed with a header describing the stall that triggered
    /// it. Returns the output URL.
    @discardableResult
    func capture(
        pid: Int32,
        duration: Int = defaultSampleDuration,
        context: PickyWatchdogCaptureContext
    ) throws -> URL {
        try ensureDirectory()
        let filename = "spin-\(filenameTimestamp()).txt"
        let outputPath = directory.appendingPathComponent(filename)
        let startedAt = clock()
        let load = systemLoad()

        try runner.runSample(pid: pid, duration: duration, outputPath: outputPath)

        let header = Self.header(
            context: context,
            startedAt: startedAt,
            finishedAt: clock(),
            heartbeatAgeAtEnd: heartbeatAgeProvider(),
            load: load
        )
        try prepend(header, to: outputPath)

        log.notice("captured spin sample at \(outputPath.path, privacy: .public) trigger=\(context.trigger.rawValue, privacy: .public)")
        return outputPath
    }

    /// Keeps at most `keeping` newest `spin-*.txt` files, deleting the rest.
    /// Other files in the directory are left untouched.
    func purgeExcess(keeping: Int) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let spinFiles = urls.filter { $0.lastPathComponent.hasPrefix("spin-") && $0.pathExtension == "txt" }
        guard spinFiles.count > keeping else { return }

        let dated = spinFiles.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        let sortedNewestFirst = dated.sorted { $0.1 > $1.1 }
        for (url, _) in sortedNewestFirst.dropFirst(keeping) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                log.error("failed to purge old sample \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    private func ensureDirectory() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Convenience used by `PickyWatchdogResponder`: capture a snapshot and
    /// prune older files so the log directory stays bounded.
    func captureSpinSampleAndPurge(
        pid: Int32,
        context: PickyWatchdogCaptureContext,
        retain: Int = 10
    ) throws -> URL {
        let url = try capture(pid: pid, context: context)
        try purgeExcess(keeping: retain)
        return url
    }

    /// Short enough to keep the capture window tight around a stall that is
    /// still in progress, long enough to show a repeating layout cycle.
    /// The trigger fires at the soft-stall edge, so a long window is no longer
    /// needed to "catch" the hang.
    static let defaultSampleDuration = 4

    private func prepend(_ header: String, to url: URL) throws {
        let body = try Data(contentsOf: url)
        var merged = Data(header.utf8)
        merged.append(body)
        try merged.write(to: url, options: .atomic)
    }

    private static func header(
        context: PickyWatchdogCaptureContext,
        startedAt: Date,
        finishedAt: Date,
        heartbeatAgeAtEnd: TimeInterval?,
        load: PickyWatchdogSystemLoad
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "=== Picky watchdog capture context ===",
            "trigger: \(context.trigger.rawValue)",
            "captureStartedAt: \(formatter.string(from: startedAt))",
            "captureFinishedAt: \(formatter.string(from: finishedAt))",
            "heartbeatAgeAtCaptureStart: \(seconds(context.heartbeatAgeAtStart))",
        ]
        if let stallStartedAt = context.stallStartedAt {
            lines.append("stallStartedAt: \(formatter.string(from: stallStartedAt))")
        }
        if let heartbeatAgeAtEnd {
            lines.append("heartbeatAgeAtCaptureEnd: \(seconds(heartbeatAgeAtEnd))")
            let stillStalled = heartbeatAgeAtEnd >= context.heartbeatAgeAtStart
            lines.append("stallOutlastedCapture: \(stillStalled)")
            if !stillStalled {
                lines.append("note: main thread recovered during this capture — trailing samples show the post-stall state")
            }
        } else {
            lines.append("heartbeatAgeAtCaptureEnd: unavailable")
        }
        if context.trigger == .spin {
            lines.append("note: captured at the spin threshold, so this window may trail the stall it reports")
        }
        lines.append(contentsOf: load.summaryLines)
        if load.loadPerCore >= 1 {
            lines.append("note: machine is oversubscribed — an idle-looking main thread here means CPU starvation, not a Picky hang")
        }
        lines.append("======================================")
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.3fs", interval)
    }

    private func filenameTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let raw = formatter.string(from: clock())
        // Replace colons so the filename is safe on case-insensitive filesystems.
        return raw.replacingOccurrences(of: ":", with: "-")
    }
}

extension PickyWatchdogSampleStore: PickyWatchdogResponder.SampleCapturing {
    func captureSpinSample(pid: Int32, context: PickyWatchdogCaptureContext) throws -> URL {
        return try captureSpinSampleAndPurge(pid: pid, context: context)
    }
}
