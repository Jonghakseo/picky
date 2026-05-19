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
    private let log = Logger(subsystem: "com.jonghakseo.picky", category: "watchdog.sample")

    init(
        directory: URL,
        runner: ProcessRunner = DefaultProcessRunner(),
        clock: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.runner = runner
        self.clock = clock
        self.fileManager = fileManager
    }

    /// Runs `sample` against the given pid for `duration` seconds and writes
    /// the result to a timestamped `spin-*.txt` file in the configured
    /// directory. Returns the output URL.
    @discardableResult
    func capture(pid: Int32, duration: Int = 10) throws -> URL {
        try ensureDirectory()
        let filename = "spin-\(filenameTimestamp()).txt"
        let outputPath = directory.appendingPathComponent(filename)
        try runner.runSample(pid: pid, duration: duration, outputPath: outputPath)
        log.notice("captured spin sample at \(outputPath.path, privacy: .public)")
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

    /// Convenience used by `PickyWatchdogResponder`: capture a 10-second
    /// snapshot and prune older files so the log directory stays bounded.
    func captureSpinSampleAndPurge(pid: Int32, retain: Int = 10) throws -> URL {
        let url = try capture(pid: pid, duration: 10)
        try purgeExcess(keeping: retain)
        return url
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
    func captureSpinSample(pid: Int32) throws -> URL {
        return try captureSpinSampleAndPurge(pid: pid)
    }
}
