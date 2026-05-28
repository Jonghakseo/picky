//
//  PickyFullscreenSessionSelection.swift
//  Picky
//
//  Pure selection fallback policy for fullscreen-local Pickle browsing.
//

import Foundation

struct PickyFullscreenSessionSelection {
    struct Candidate: Equatable {
        let id: String
        let updatedAt: Date
    }

    static func candidates(from sessions: [PickySessionListViewModel.SessionCard]) -> [Candidate] {
        sessions.map { Candidate(id: $0.id, updatedAt: $0.updatedAt) }
    }

    static func resolvedSessionID(
        requestedSessionID: String?,
        storedSelectedSessionID: String?,
        viewModelSelectedSessionID: String?,
        candidates: [Candidate]
    ) -> String? {
        guard !candidates.isEmpty else { return nil }
        let candidateIDs = Set(candidates.map(\.id))

        for id in [requestedSessionID, storedSelectedSessionID, viewModelSelectedSessionID].compactMap(normalizedID) {
            if candidateIDs.contains(id) {
                return id
            }
        }

        return mostRecentlyUpdatedCandidate(in: candidates)?.id
    }

    private static func normalizedID(_ id: String?) -> String? {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func mostRecentlyUpdatedCandidate(in candidates: [Candidate]) -> Candidate? {
        var latest: Candidate?
        for candidate in candidates {
            guard let current = latest else {
                latest = candidate
                continue
            }
            if candidate.updatedAt > current.updatedAt {
                latest = candidate
            }
        }
        return latest
    }
}
