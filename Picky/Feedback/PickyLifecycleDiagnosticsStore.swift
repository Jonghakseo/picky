//
//  PickyLifecycleDiagnosticsStore.swift
//  Picky
//
//  Persists only scalar app-lifecycle state so the next launch can distinguish
//  a normal termination from a prior crash or force-quit. This is deliberately
//  one atomic snapshot, never an append-only history.
//

import Foundation

enum PickyLifecycleExitReason: String, Codable, Sendable {
    case normal
    case update
}

struct PickyLifecycleRun: Codable, Equatable, Sendable {
    let runID: String
    let processID: Int32
    let appVersion: String
    let appBuild: String
    let launchedAt: Date
    var cleanExit: Bool
    var exitedAt: Date?
    var exitReason: PickyLifecycleExitReason?
}

struct PickyLifecycleDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var current: PickyLifecycleRun
    var previous: PickyLifecycleRun?
}

/// Fixed-size, best-effort lifecycle persistence. The snapshot contains only
/// process/version/timestamp scalar state; it intentionally has no session,
/// prompt, path, browser, or daemon data.
final class PickyLifecycleDiagnosticsStore {
    static let filename = "picky-lifecycle.json"
    static let schemaVersion = 1

    private let logsDirectory: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let makeRunID: () -> String
    private let processID: () -> Int32
    private var currentRunID: String?

    init(
        logsDirectory: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeRunID: @escaping () -> String = { UUID().uuidString },
        processID: @escaping () -> Int32 = { ProcessInfo.processInfo.processIdentifier }
    ) {
        self.logsDirectory = logsDirectory
        self.fileManager = fileManager
        self.now = now
        self.makeRunID = makeRunID
        self.processID = processID
    }

    var snapshotURL: URL {
        logsDirectory.appendingPathComponent(Self.filename)
    }

    /// Rotates the immediately preceding current run into `previous` and marks
    /// the new current run unclean until a normal termination is observed.
    @discardableResult
    func recordLaunch(appVersion: String, appBuild: String) -> PickyLifecycleDiagnosticsSnapshot? {
        let previous = readSnapshot()?.current
        let runID = makeRunID()
        let snapshot = PickyLifecycleDiagnosticsSnapshot(
            schemaVersion: Self.schemaVersion,
            current: PickyLifecycleRun(
                runID: runID,
                processID: processID(),
                appVersion: appVersion,
                appBuild: appBuild,
                launchedAt: now(),
                cleanExit: false,
                exitedAt: nil,
                exitReason: nil
            ),
            previous: previous
        )
        guard write(snapshot) else { return nil }
        currentRunID = runID
        return snapshot
    }

    /// Mark only this process's current run as clean. A Sparkle update marker
    /// wins over the subsequent normal termination callback Sparkle triggers.
    @discardableResult
    func markCurrentRunClean(reason: PickyLifecycleExitReason) -> PickyLifecycleDiagnosticsSnapshot? {
        guard let currentRunID,
              var snapshot = readSnapshot(),
              snapshot.current.runID == currentRunID else { return nil }
        if snapshot.current.exitReason == .update, reason == .normal {
            return snapshot
        }
        snapshot.current.cleanExit = true
        snapshot.current.exitedAt = now()
        snapshot.current.exitReason = reason
        return write(snapshot) ? snapshot : nil
    }

    static func boundedSnapshotText(
        from logsDirectory: URL,
        maxBytes: Int,
        fileManager: FileManager = .default
    ) -> String {
        let url = logsDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder.diagnosticsDecoder.decode(PickyLifecycleDiagnosticsSnapshot.self, from: data),
              let rendered = try? JSONEncoder.diagnosticsEncoder.encode(snapshot),
              let text = String(data: rendered, encoding: .utf8) else {
            return "(Picky lifecycle snapshot unavailable or invalid)\n"
        }
        return PickyDiagnosticTextRedactor.truncateUTF8(
            PickyDiagnosticTextRedactor.redact(text),
            maxBytes: maxBytes,
            keepingNewest: false
        )
    }

    private func readSnapshot() -> PickyLifecycleDiagnosticsSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder.diagnosticsDecoder.decode(PickyLifecycleDiagnosticsSnapshot.self, from: data)
    }

    private func write(_ snapshot: PickyLifecycleDiagnosticsSnapshot) -> Bool {
        do {
            try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder.diagnosticsEncoder.encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

private extension JSONEncoder {
    static var diagnosticsEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var diagnosticsDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
