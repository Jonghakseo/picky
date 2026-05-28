//
//  PickyFullscreenFileDiffProvider.swift
//  Picky
//
//  Lazy git diff metadata for the fullscreen 변경사항 panel.
//

import Foundation

@MainActor
final class PickyFullscreenFileDiffProvider {
    struct Numstat: Equatable {
        let insertions: Int
        let deletions: Int
    }

    let cwd: String

    private var cachedNumstat: [String: Numstat]?
    private var diffCache: [String: String?] = [:]

    init(cwd: String) {
        self.cwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetchNumstat() async -> [String: Numstat] {
        if let cachedNumstat { return cachedNumstat }
        guard !cwd.isEmpty else {
            cachedNumstat = [:]
            return [:]
        }

        let output = await Self.runGit(arguments: ["diff", "--numstat", "HEAD"], cwd: cwd)
        let parsed = output.map(Self.parseNumstat(_:)) ?? [:]
        cachedNumstat = parsed
        return parsed
    }

    func fetchDiff(path: String) async -> String? {
        if let cached = diffCache[path] { return cached }
        guard !cwd.isEmpty, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diffCache[path] = nil
            return nil
        }

        let output = await Self.runGit(arguments: ["diff", "HEAD", "--", path], cwd: cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = output?.isEmpty == false ? output : nil
        diffCache[path] = diff
        return diff
    }

    nonisolated static func parseNumstat(_ output: String) -> [String: Numstat] {
        output.split(whereSeparator: { $0.isNewline }).reduce(into: [:]) { result, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let insertions = Int(fields[0]),
                  let deletions = Int(fields[1]) else { return }
            let path = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            result[path] = Numstat(insertions: insertions, deletions: deletions)
        }
    }

    private static func runGit(arguments: [String], cwd: String) async -> String? {
        await withCheckedContinuation { continuation in
            PickyGitRepositoryStatus.subprocessQueue.addOperation {
                continuation.resume(returning: runGitSynchronously(arguments: arguments, cwd: cwd))
            }
        }
    }

    nonisolated private static func runGitSynchronously(arguments: [String], cwd: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        switch PickyGitRepositoryStatus.runProcessWithTimeout(
            process,
            timeout: PickyGitRepositoryStatus.subprocessTimeout,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        ) {
        case .success(let exitCode, let stdout, _):
            return exitCode == 0 ? stdout : nil
        case .failure:
            return nil
        }
    }
}
