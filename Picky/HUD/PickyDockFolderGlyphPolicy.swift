//
//  PickyDockFolderGlyphPolicy.swift
//  Picky
//
//  Chooses which members a collapsed folder badge shows. Unread only covers
//  the attention states, so a folder that picked members by stored order
//  could hide every running or blocked Pickle behind its `+N` cell.
//

enum PickyDockFolderGlyphPolicy {
    /// Lower is more important. Presentation only: this ordering never
    /// reaches the stored member array.
    static func statusPriority(_ status: PickySessionStatus) -> Int {
        switch status {
        case .blocked: 0
        case .waiting_for_input: 1
        case .failed: 2
        case .running: 3
        case .queued: 4
        case .completed: 5
        case .cancelled: 6
        }
    }

    /// Indices of the members to draw, highest priority first, ties broken by
    /// stored order so the badge is stable while nothing changes state.
    static func glyphIndices(statuses: [PickySessionStatus], cellCount: Int) -> [Int] {
        guard cellCount > 0 else { return [] }
        return statuses.indices
            .sorted { lhs, rhs in
                let lhsPriority = statusPriority(statuses[lhs])
                let rhsPriority = statusPriority(statuses[rhs])
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs < rhs
            }
            .prefix(cellCount)
            .map { $0 }
    }

    /// Members hidden behind the `+N` cell, or 0 when every member is drawn.
    static func overflowCount(memberCount: Int, glyphCellCount: Int) -> Int {
        max(0, memberCount - glyphCellCount)
    }
}
