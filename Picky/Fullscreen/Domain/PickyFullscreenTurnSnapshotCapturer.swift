//
//  PickyFullscreenTurnSnapshotCapturer.swift
//  Picky
//
//  Captures git HEAD plus ephemeral working-tree refs for fullscreen turn boundaries.
//

import Foundation

@MainActor
final class PickyFullscreenTurnSnapshotCapturer {
    typealias GitRunner = @Sendable (_ arguments: [String], _ cwd: String) async -> String?

    let cwd: String
    let store: PickyFullscreenTurnSnapshotStore
    private let gitRunner: GitRunner

    init(
        cwd: String,
        store: PickyFullscreenTurnSnapshotStore,
        gitRunner: @escaping GitRunner = { arguments, cwd in await PickyFullscreenTurnSnapshotCapturer.runGit(arguments: arguments, cwd: cwd) }
    ) {
        self.cwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        self.store = store
        self.gitRunner = gitRunner
    }

    func captureBoundary(sessionID: String, turnID: String) async {
        guard let snapshot = await captureSnapshot() else { return }
        store.record(sessionID: sessionID, turnID: turnID, snapshot: snapshot)
    }

    func captureSnapshot() async -> PickyFullscreenTurnGitSnapshot? {
        await Self.captureSnapshot(cwd: cwd, gitRunner: gitRunner)
    }

    static func captureSnapshot(
        cwd: String?,
        gitRunner: @escaping GitRunner = { arguments, cwd in await PickyFullscreenTurnSnapshotCapturer.runGit(arguments: arguments, cwd: cwd) }
    ) async -> PickyFullscreenTurnGitSnapshot? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty else { return nil }
        guard let head = await gitRunner(["rev-parse", "HEAD"], trimmedCwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !head.isEmpty else { return nil }

        let worktree = await gitRunner(["stash", "create", "--include-untracked"], trimmedCwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PickyFullscreenTurnGitSnapshot(
            capturedAt: Date(),
            headSHA: head,
            worktreeSHA: worktree?.isEmpty == false ? worktree : nil
        )
    }

    static func runGit(arguments: [String], cwd: String) async -> String? {
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
