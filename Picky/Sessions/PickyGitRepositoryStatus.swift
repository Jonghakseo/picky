//
//  PickyGitRepositoryStatus.swift
//  Picky
//
//  Lightweight git metadata used by the side-agent HUD cards.
//

import Foundation

struct PickyGitRepositoryStatus: Equatable {
    let repositoryName: String
    let branchName: String
    let hasUncommittedChanges: Bool
    let insertions: Int
    let deletions: Int
    let aheadCount: Int
    let behindCount: Int

    var repositoryDisplayName: String {
        hasUncommittedChanges ? "\(repositoryName)*" : repositoryName
    }

    static func load(cwd: String?) async -> PickyGitRepositoryStatus? {
        await Task.detached(priority: .utility) {
            loadSynchronously(cwd: cwd)
        }.value
    }

    static func loadSynchronously(cwd: String?) -> PickyGitRepositoryStatus? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedCwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        guard git(["rev-parse", "--is-inside-work-tree"], cwd: trimmedCwd)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true",
              let topLevel = git(["rev-parse", "--show-toplevel"], cwd: trimmedCwd)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !topLevel.isEmpty else {
            return nil
        }

        let repositoryName = URL(fileURLWithPath: topLevel).lastPathComponent
        let branchName = currentBranchName(cwd: trimmedCwd)
        let statusOutput = git(["status", "--porcelain"], cwd: trimmedCwd) ?? ""
        let diffStats = parseNumstat(git(["diff", "--numstat", "HEAD", "--"], cwd: trimmedCwd, allowsFailure: true) ?? "")
        let position = parseAheadBehind(git(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], cwd: trimmedCwd, allowsFailure: true) ?? "")

        return PickyGitRepositoryStatus(
            repositoryName: repositoryName,
            branchName: branchName,
            hasUncommittedChanges: !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            insertions: diffStats.insertions,
            deletions: diffStats.deletions,
            aheadCount: position.ahead,
            behindCount: position.behind
        )
    }

    static func parseNumstat(_ output: String) -> (insertions: Int, deletions: Int) {
        output.split(whereSeparator: { $0.isNewline }).reduce(into: (insertions: 0, deletions: 0)) { result, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2,
                  let insertions = Int(fields[0]),
                  let deletions = Int(fields[1]) else { return }
            result.insertions += insertions
            result.deletions += deletions
        }
    }

    static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int) {
        let fields = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard fields.count >= 2,
              let behind = Int(fields[0]),
              let ahead = Int(fields[1]) else {
            return (ahead: 0, behind: 0)
        }
        return (ahead: ahead, behind: behind)
    }

    private static func currentBranchName(cwd: String) -> String {
        let branch = git(["branch", "--show-current"], cwd: cwd)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !branch.isEmpty { return branch }
        let shortHash = git(["rev-parse", "--short", "HEAD"], cwd: cwd, allowsFailure: true)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return shortHash.isEmpty ? "detached" : shortHash
    }

    private static func git(_ arguments: [String], cwd: String, allowsFailure: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 || allowsFailure else { return nil }
        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
