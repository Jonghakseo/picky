//
//  PickyHUDDockSummaryPolicy.swift
//  Picky
//
//  Pure aggregation for the minimized dock's status summary. When the dock is
//  collapsed the session tiles disappear, so this policy projects the live
//  session statuses into a small ordered list of (status, count) chips the
//  strip renders beneath itself. Attention-first ordering is intentionally
//  avoided here; the collapsed summary mirrors the reading order the user saw
//  in the expanded dock (running, waiting, failed).
//

import Foundation

/// Status buckets surfaced in the minimized dock summary. Every session maps to
/// exactly one bucket so the collapsed strip accounts for all pickles, not just
/// the attention states. Queued and cancelled share the neutral bucket since
/// both render with the same neutral tone.
enum PickyHUDDockSummaryStatus: CaseIterable, Equatable, Hashable {
    case running
    case waiting
    case failed
    case completed
    case neutral

    init(_ status: PickySessionStatus) {
        switch status {
        case .running:
            self = .running
        case .waiting_for_input, .blocked:
            self = .waiting
        case .failed:
            self = .failed
        case .completed:
            self = .completed
        case .queued, .cancelled:
            self = .neutral
        }
    }
}

struct PickyHUDDockSummaryItem: Equatable {
    let status: PickyHUDDockSummaryStatus
    let count: Int
}

enum PickyHUDDockSummaryPolicy {
    /// Ordered summary chips for the minimized dock. Every session is bucketed,
    /// and buckets with a zero count are omitted so a dock with only, say,
    /// running and completed pickles shows exactly two chips. Order follows
    /// `PickyHUDDockSummaryStatus.allCases` (running, waiting, failed,
    /// completed, neutral).
    static func summary(for statuses: [PickySessionStatus]) -> [PickyHUDDockSummaryItem] {
        var counts: [PickyHUDDockSummaryStatus: Int] = [:]
        for status in statuses {
            counts[PickyHUDDockSummaryStatus(status), default: 0] += 1
        }
        return PickyHUDDockSummaryStatus.allCases.compactMap { bucket in
            guard let count = counts[bucket], count > 0 else { return nil }
            return PickyHUDDockSummaryItem(status: bucket, count: count)
        }
    }

    /// True when there are no sessions at all, so the view can render an empty
    /// summary (strip only).
    static func isCalm(_ summary: [PickyHUDDockSummaryItem]) -> Bool {
        summary.isEmpty
    }
}
