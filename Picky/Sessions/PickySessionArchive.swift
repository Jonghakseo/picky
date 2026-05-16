//
//  PickySessionArchive.swift
//  Picky
//

import Foundation

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
