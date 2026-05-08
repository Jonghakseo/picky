import Foundation

struct DiffReviewSource: Equatable {
    enum Kind: Equatable {
        case diffFile(URL)
        case repository(URL)
    }

    var kind: Kind

    static func fromCommandLine() -> DiffReviewSource {
        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--diff", index + 1 < args.count {
                return DiffReviewSource(kind: .diffFile(URL(fileURLWithPath: NSString(string: args[index + 1]).expandingTildeInPath)))
            }
            if arg == "--cwd", index + 1 < args.count {
                return DiffReviewSource(kind: .repository(URL(fileURLWithPath: NSString(string: args[index + 1]).expandingTildeInPath)))
            }
            if arg == "--fixture" {
                return DiffReviewSource(kind: .diffFile(Self.fixtureURL()))
            }
            index += 1
        }
        return DiffReviewSource(kind: .repository(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
    }

    static func fixtureURL() -> URL {
        let sourceFile = URL(fileURLWithPath: #filePath)
        return sourceFile
            .deletingLastPathComponent() // DiffReviewPlayground
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Fixtures/sample.diff")
    }
}

enum DiffReviewLoadError: LocalizedError {
    case notGitRepository(String)
    case commandFailed(String)
    case emptyDiff

    var errorDescription: String? {
        switch self {
        case .notGitRepository(let path):
            "Not a git repository: \(path)"
        case .commandFailed(let message):
            message
        case .emptyDiff:
            "No changed files found. Use --fixture to open sample data."
        }
    }
}

struct DiffReviewSnapshotLoader {
    func load(source: DiffReviewSource) throws -> DiffReviewSnapshot {
        switch source.kind {
        case .diffFile(let url):
            let text = try String(contentsOf: url, encoding: .utf8)
            return UnifiedDiffParser().parse(
                text,
                title: "Sample changed files",
                repoRoot: url.deletingLastPathComponent().path,
                subtitle: url.lastPathComponent
            )
        case .repository(let url):
            return try loadRepository(cwd: url.path)
        }
    }

    private func loadRepository(cwd: String) throws -> DiffReviewSnapshot {
        let repoRootOutput = try runGit(["rev-parse", "--show-toplevel"], cwd: cwd)
        let repoRoot = repoRootOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoRoot.isEmpty else { throw DiffReviewLoadError.notGitRepository(cwd) }

        let branch = (try? runGit(["branch", "--show-current"], cwd: repoRoot))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHead = (try? runGit(["rev-parse", "--verify", "HEAD"], cwd: repoRoot)) != nil
        let diff = try workingTreeSnapshotDiff(repoRoot: repoRoot, hasHead: hasHead)
        if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DiffReviewLoadError.emptyDiff
        }

        let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
        let branchLabel = branch?.isEmpty == false ? branch! : "HEAD"
        let baseLabel = hasHead ? "HEAD → working tree" : "Empty tree → working tree"
        return UnifiedDiffParser().parse(
            diff,
            title: "\(repoName) · \(branchLabel)",
            repoRoot: repoRoot,
            subtitle: baseLabel
        )
    }

    private func workingTreeSnapshotDiff(repoRoot: String, hasHead: Bool) throws -> String {
        let tempIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-diff-review-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(at: tempIndex) }

        var env = ProcessInfo.processInfo.environment
        env["GIT_INDEX_FILE"] = tempIndex.path

        if hasHead {
            _ = try runGit(["read-tree", "HEAD"], cwd: repoRoot, environment: env)
        }
        _ = try runGit(["add", "-A", "--", "."], cwd: repoRoot, environment: env)

        let diffArgs: [String] = hasHead
            ? ["diff", "--cached", "--find-renames", "-M", "--no-ext-diff", "HEAD", "--"]
            : ["diff", "--cached", "--find-renames", "-M", "--no-ext-diff", "--root", "--"]
        return try runGit(diffArgs, cwd: repoRoot, environment: env)
    }

    @discardableResult
    private func runGit(_ args: [String], cwd: String, environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + args
        if let environment { process.environment = environment }

        let stdoutURL = FileManager.default.temporaryDirectory.appendingPathComponent("picky-git-stdout-\(UUID().uuidString).txt")
        let stderrURL = FileManager.default.temporaryDirectory.appendingPathComponent("picky-git-stderr-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DiffReviewLoadError.commandFailed(error.localizedDescription)
        }

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()
        let out = String(data: (try? Data(contentsOf: stdoutURL)) ?? Data(), encoding: .utf8) ?? ""
        let err = String(data: (try? Data(contentsOf: stderrURL)) ?? Data(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiffReviewLoadError.commandFailed(message.isEmpty ? "git \(args.joined(separator: " ")) failed" : message)
        }
        return out
    }
}
