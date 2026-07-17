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

/// Coarse status buckets surfaced in the minimized dock summary. Terminal and
/// neutral states (completed, cancelled, queued) are intentionally excluded so
/// the collapsed strip only carries the "still needs an eye on it" mix.
enum PickyHUDDockSummaryStatus: CaseIterable, Equatable, Hashable {
    case running
    case waiting
    case failed

    init?(_ status: PickySessionStatus) {
        switch status {
        case .running:
            self = .running
        case .waiting_for_input, .blocked:
            self = .waiting
        case .failed:
            self = .failed
        case .queued, .completed, .cancelled:
            return nil
        }
    }
}

struct PickyHUDDockSummaryItem: Equatable {
    let status: PickyHUDDockSummaryStatus
    let count: Int
}

enum PickyHUDDockSummaryPolicy {
    /// Ordered summary chips for the minimized dock. Buckets with a zero count
    /// are omitted so a calm dock naturally collapses to fewer (or no) chips.
    /// Order follows `PickyHUDDockSummaryStatus.allCases` (running, waiting,
    /// failed) to match the expanded dock's top-to-bottom reading order.
    static func summary(for statuses: [PickySessionStatus]) -> [PickyHUDDockSummaryItem] {
        var counts: [PickyHUDDockSummaryStatus: Int] = [:]
        for status in statuses {
            guard let bucket = PickyHUDDockSummaryStatus(status) else { continue }
            counts[bucket, default: 0] += 1
        }
        return PickyHUDDockSummaryStatus.allCases.compactMap { bucket in
            guard let count = counts[bucket], count > 0 else { return nil }
            return PickyHUDDockSummaryItem(status: bucket, count: count)
        }
    }

    /// True when no bucketed (running/waiting/failed) session exists, so the
    /// view can fall back to a single neutral total chip instead of an empty
    /// summary. `total` is the caller's overall session count for that chip.
    static func isCalm(_ summary: [PickyHUDDockSummaryItem]) -> Bool {
        summary.isEmpty
    }
}
