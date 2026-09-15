// Shared group presentation order. Persisted membership remains unchanged.
import Foundation

enum PickyDockGroupRecencyPolicy {
    static func groups(in layout: PickyDockLayout, sessions: [PickyConversationSessionCard]) -> [String: [String]] {
        let dates = Dictionary(sessions.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(uniqueKeysWithValues: layout.groups.map { group in
            (group.id, memberIDs(group.memberSessionIDs, updatedAtByID: dates))
        })
    }

    static func memberIDs(_ memberIDs: [String], updatedAtByID: [String: Date]) -> [String] {
        memberIDs.enumerated().sorted { lhs, rhs in
            let left = updatedAtByID[lhs.element]
            let right = updatedAtByID[rhs.element]
            if left != right {
                guard let left else { return false }
                guard let right else { return true }
                return left > right
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

enum PickyDockFolderGlyphPolicy {
    /// The folder previews the same leading members as the group list.
    static func overflowCount(memberCount: Int, glyphCellCount: Int) -> Int {
        max(0, memberCount - glyphCellCount)
    }
}
