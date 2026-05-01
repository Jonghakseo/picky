//
//  PickySessionPolish.swift
//  Picky
//
//  Small polish helpers for diff preview, archive/search, and friendly local
//  dependency errors.
//

import Foundation

struct PickyDiffPreview: Equatable {
    struct FileDiff: Equatable, Identifiable {
        var id: String { path }
        let path: String
        let text: String
        let isTruncated: Bool
    }

    let files: [FileDiff]
    let totalOriginalCharacters: Int
}

struct PickyDiffPreviewBuilder {
    let maxCharactersPerFile: Int

    init(maxCharactersPerFile: Int = 12_000) {
        self.maxCharactersPerFile = max(1, maxCharactersPerFile)
    }

    func build(from unifiedDiff: String) -> PickyDiffPreview {
        var grouped: [(path: String, lines: [String])] = []
        var currentPath = "unified.diff"
        var currentLines: [String] = []

        for line in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                if !currentLines.isEmpty { grouped.append((currentPath, currentLines)) }
                currentPath = Self.path(fromDiffHeader: line) ?? "unified.diff"
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }
        if !currentLines.isEmpty { grouped.append((currentPath, currentLines)) }

        let files = grouped.map { group -> PickyDiffPreview.FileDiff in
            let text = group.lines.joined(separator: "\n")
            if text.count <= maxCharactersPerFile {
                return PickyDiffPreview.FileDiff(path: group.path, text: text, isTruncated: false)
            }
            let end = text.index(text.startIndex, offsetBy: maxCharactersPerFile)
            return PickyDiffPreview.FileDiff(path: group.path, text: String(text[..<end]) + "\n[diff truncated by Picky]", isTruncated: true)
        }
        return PickyDiffPreview(files: files, totalOriginalCharacters: unifiedDiff.count)
    }

    private static func path(fromDiffHeader line: String) -> String? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { return nil }
        return parts[3].hasPrefix("b/") ? String(parts[3].dropFirst(2)) : parts[3]
    }
}

struct PickySessionArchive: Equatable {
    private(set) var active: [PickyAgentSession]
    private(set) var archived: [PickyAgentSession]

    init(active: [PickyAgentSession] = [], archived: [PickyAgentSession] = []) {
        self.active = active
        self.archived = archived
    }

    mutating func archive(sessionID: String) {
        guard let index = active.firstIndex(where: { $0.id == sessionID }) else { return }
        archived.append(active.remove(at: index))
    }

    func search(_ query: String) -> [PickyAgentSession] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sessions = active + archived
        guard !normalized.isEmpty else { return sessions }
        return sessions.filter { session in
            let haystack = [
                session.title,
                session.cwd,
                session.status.rawValue,
                session.lastSummary,
                session.finalAnswer,
                session.artifacts.compactMap { $0.url?.absoluteString }.joined(separator: " ")
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            return haystack.contains(normalized)
        }
    }
}

enum PickyFriendlyRuntimeError: LocalizedError, Equatable {
    case missingDaemon(path: String)
    case missingPiSDK(path: String)
    case missingPiExecutable
    case daemonCrashed(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .missingDaemon(let path): "picky-agentd is not available at \(path). Rebuild the daemon or check Settings → Daemon."
        case .missingPiSDK(let path): "Pi SDK is not available at \(path). Install or update local Pi before starting sessions."
        case .missingPiExecutable: "The pi executable was not found in PATH. Install Pi or add it to PATH, then restart Picky."
        case .daemonCrashed(let detail): "picky-agentd stopped unexpectedly. Open logs for details. \(detail)"
        case .permissionDenied(let permission): "Picky does not have \(permission) permission. Grant it in macOS Settings; the task can continue with reduced context."
        }
    }
}

struct PickyRuntimeDependencyChecker {
    var fileManager: FileManager = .default
    var piSDKPath: String = "/usr/local/lib/node_modules/@mariozechner/pi-coding-agent"
    var pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? ""

    func missingPiSDKErrorIfNeeded() -> PickyFriendlyRuntimeError? {
        fileManager.fileExists(atPath: piSDKPath) ? nil : .missingPiSDK(path: piSDKPath)
    }

    func missingPiExecutableErrorIfNeeded() -> PickyFriendlyRuntimeError? {
        for directory in pathEnvironment.split(separator: ":").map(String.init) {
            if fileManager.isExecutableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent("pi").path) { return nil }
        }
        return .missingPiExecutable
    }
}
