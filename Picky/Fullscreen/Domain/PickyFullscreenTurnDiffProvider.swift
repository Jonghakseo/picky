//
//  PickyFullscreenTurnDiffProvider.swift
//  Picky
//
//  Lazy git diff resolver for fullscreen turn-scoped changed-file cards.
//

import Combine
import Foundation

@MainActor
final class PickyFullscreenTurnDiffProvider: ObservableObject {
    typealias GitRunner = @Sendable (_ arguments: [String], _ cwd: String) async -> String?

    @Published private(set) var diffsByTurnID: [String: [PickyChangedFile]] = [:]

    private(set) var cwd: String
    private let gitRunner: GitRunner
    private var cache: [String: [PickyChangedFile]] = [:]

    init(
        cwd: String = "",
        gitRunner: @escaping GitRunner = { arguments, cwd in await PickyFullscreenTurnSnapshotCapturer.runGit(arguments: arguments, cwd: cwd) }
    ) {
        self.cwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gitRunner = gitRunner
    }

    func configure(cwd: String?) {
        let next = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard next != self.cwd else { return }
        self.cwd = next
        cache.removeAll()
        diffsByTurnID.removeAll()
    }

    func fetchDiff(turnID: String, startRef: String, endRef: String) async {
        let key = cacheKey(turnID: turnID, startRef: startRef, endRef: endRef)
        if let cached = cache[key] {
            diffsByTurnID[turnID] = cached
            return
        }
        guard !cwd.isEmpty, !turnID.isEmpty, !startRef.isEmpty, !endRef.isEmpty else {
            cache[key] = []
            diffsByTurnID[turnID] = []
            return
        }

        let output = await gitRunner(["diff", "\(startRef)..\(endRef)", "--name-status"], cwd)
        let parsed = output.map(Self.parseNameStatus(_:)) ?? []
        cache[key] = parsed
        diffsByTurnID[turnID] = parsed
    }

    func fetchLastTurnDiff(turnID: String, startRef: String) async {
        guard !cwd.isEmpty, !turnID.isEmpty, !startRef.isEmpty else {
            diffsByTurnID[turnID] = []
            return
        }
        guard let endSnapshot = await PickyFullscreenTurnSnapshotCapturer.captureSnapshot(cwd: cwd, gitRunner: gitRunner) else {
            diffsByTurnID[turnID] = []
            return
        }
        await fetchDiff(turnID: turnID, startRef: startRef, endRef: endSnapshot.effectiveRef)
    }

    nonisolated static func parseNameStatus(_ output: String) -> [PickyChangedFile] {
        output.split(whereSeparator: { $0.isNewline }).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            let rawStatus = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawStatus.isEmpty else { return nil }
            let status = normalizedStatus(rawStatus)
            let pathFieldIndex = rawStatus.uppercased().hasPrefix("R") || rawStatus.uppercased().hasPrefix("C") ? min(2, fields.count - 1) : 1
            let path = String(fields[pathFieldIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return PickyChangedFile(path: path, status: status, summary: nil)
        }
    }

    nonisolated private static func normalizedStatus(_ rawStatus: String) -> String {
        switch rawStatus.uppercased().first {
        case "A": "added"
        case "M": "modified"
        case "D": "deleted"
        case "R": "renamed"
        case "C": "copied"
        default: rawStatus
        }
    }

    private func cacheKey(turnID: String, startRef: String, endRef: String) -> String {
        "\(turnID):\(startRef)..\(endRef)"
    }
}
