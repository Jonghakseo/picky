//
//  PickyHubStatisticsModels.swift
//  Picky
//
//  Wire + view models for the hub's statistics. The daemon aggregates the
//  unfiltered snapshot (every Pickle, every day); period/project filtering is
//  a pure client-side policy so the dashboard summary and the statistics page
//  always agree.
//

import Foundation
import SwiftUI

/// Work type assigned to a Pickle by the daemon's background classifier.
enum PickyHubWorkCategory: String, Codable, CaseIterable, Identifiable {
    case fix
    case research
    case create
    case review
    case unclassified

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .fix: "hub.stats.category.fix"
        case .research: "hub.stats.category.research"
        case .create: "hub.stats.category.create"
        case .review: "hub.stats.category.review"
        case .unclassified: "hub.stats.category.unclassified"
        }
    }

    var title: String {
        switch self {
        case .fix: L10n.t("hub.stats.category.fix")
        case .research: L10n.t("hub.stats.category.research")
        case .create: L10n.t("hub.stats.category.create")
        case .review: L10n.t("hub.stats.category.review")
        case .unclassified: L10n.t("hub.stats.category.unclassified")
        }
    }

    /// Display order for the distribution chart. `unclassified` always last.
    static let chartOrder: [PickyHubWorkCategory] = [.fix, .research, .create, .review, .unclassified]

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PickyHubWorkCategory(rawValue: raw) ?? .unclassified
    }
}

struct PickyHubPickleRecord: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    /// Project label derived from the Pickle cwd (last path component).
    let project: String
    let cwd: String?
    let createdAt: Date
    let lastActivityAt: Date
    /// User-authored messages after the first instruction.
    let followUpCount: Int
    /// Instructions the main Picky agent sent into this Pickle.
    let delegationCount: Int
    /// Reviewer/verifier style subagent passes.
    let reviewCount: Int
    let category: PickyHubWorkCategory
}

struct PickyHubUsageDay: Codable, Equatable, Identifiable {
    /// `yyyy-MM-dd` in the local calendar of the machine that recorded it.
    let day: String
    let totalTokens: Int

    var id: String { day }
}

struct PickyHubModelUsage: Codable, Equatable, Identifiable {
    let provider: String
    let model: String
    let inputTokens: Int
    /// Output plus reasoning tokens.
    let outputTokens: Int
    /// Cache read plus cache write tokens.
    let cacheTokens: Int
    /// `yyyy-MM-dd` of the newest message that contributed.
    let lastUsedDay: String?

    var id: String { "\(provider)/\(model)" }
    var totalTokens: Int { inputTokens + outputTokens + cacheTokens }
}

/// A single model turn's usage, day-stamped so the client can filter by period.
struct PickyHubUsageSample: Codable, Equatable {
    let day: String
    let provider: String
    let model: String
    let project: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
}

struct PickyHubStatisticsSnapshot: Codable, Equatable {
    let generatedAt: Date
    let records: [PickyHubPickleRecord]
    let usageSamples: [PickyHubUsageSample]
    /// Present when the classifier is still catching up on some Pickles.
    let pendingClassificationCount: Int

    static let empty = PickyHubStatisticsSnapshot(generatedAt: .distantPast, records: [], usageSamples: [], pendingClassificationCount: 0)
}

enum PickyHubStatisticsPeriod: String, CaseIterable, Identifiable {
    case thisWeek
    case thisMonth
    case lastThreeMonths
    case all

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .thisWeek: "hub.stats.period.thisWeek"
        case .thisMonth: "hub.stats.period.thisMonth"
        case .lastThreeMonths: "hub.stats.period.lastThreeMonths"
        case .all: "hub.stats.period.all"
        }
    }

    /// Inclusive lower bound, `nil` for all time.
    func startDate(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)?.start
        case .lastThreeMonths:
            return calendar.date(byAdding: .month, value: -3, to: calendar.startOfDay(for: now))
        case .all:
            return nil
        }
    }
}

/// Project filter. `nil` project means every project.
struct PickyHubStatisticsFilter: Equatable {
    var period: PickyHubStatisticsPeriod = .thisWeek
    var project: String?
}

// MARK: - Derived views

struct PickyHubCategoryShare: Identifiable, Equatable {
    let category: PickyHubWorkCategory
    let count: Int
    let share: Double

    var id: PickyHubWorkCategory { category }
}

struct PickyHubWorkInsights: Equatable {
    struct TopCategory: Equatable {
        let category: PickyHubWorkCategory
        let count: Int
        let share: Double
    }

    struct DeepestPickle: Equatable {
        let record: PickyHubPickleRecord
    }

    struct FocusedProject: Equatable {
        let project: String
        let count: Int
    }

    let topCategory: TopCategory?
    let deepestPickle: DeepestPickle?
    let focusedProject: FocusedProject?
    let distribution: [PickyHubCategoryShare]
    let totalCount: Int
}

struct PickyHubUsageSummary: Equatable {
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let days: [PickyHubUsageDay]
    let models: [PickyHubModelUsage]
}

/// Pure filtering + aggregation shared by the dashboard and statistics page.
enum PickyHubStatisticsAggregator {
    static func records(
        in snapshot: PickyHubStatisticsSnapshot,
        filter: PickyHubStatisticsFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PickyHubPickleRecord] {
        let start = filter.period.startDate(now: now, calendar: calendar)
        return snapshot.records
            .filter { record in
                if let start, record.lastActivityAt < start { return false }
                if let project = filter.project, record.project != project { return false }
                return true
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    static func projects(in snapshot: PickyHubStatisticsSnapshot) -> [String] {
        var counts: [String: Int] = [:]
        for record in snapshot.records { counts[record.project, default: 0] += 1 }
        return counts.keys.sorted { lhs, rhs in
            let lc = counts[lhs] ?? 0
            let rc = counts[rhs] ?? 0
            return lc != rc ? lc > rc : lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    static func workInsights(for records: [PickyHubPickleRecord]) -> PickyHubWorkInsights {
        let total = records.count
        var counts: [PickyHubWorkCategory: Int] = [:]
        for record in records { counts[record.category, default: 0] += 1 }
        let distribution = PickyHubWorkCategory.chartOrder.compactMap { category -> PickyHubCategoryShare? in
            let count = counts[category] ?? 0
            guard count > 0 else { return nil }
            return PickyHubCategoryShare(category: category, count: count, share: total == 0 ? 0 : Double(count) / Double(total))
        }
        let top = distribution
            .filter { $0.category != .unclassified }
            .max { lhs, rhs in lhs.count != rhs.count ? lhs.count < rhs.count : chartIndex(lhs.category) > chartIndex(rhs.category) }
        let deepest = records.max { lhs, rhs in
            let l = lhs.followUpCount + lhs.delegationCount
            let r = rhs.followUpCount + rhs.delegationCount
            return l != r ? l < r : lhs.lastActivityAt < rhs.lastActivityAt
        }
        var projectCounts: [String: Int] = [:]
        for record in records { projectCounts[record.project, default: 0] += 1 }
        let focused = projectCounts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }
        return PickyHubWorkInsights(
            topCategory: top.map { .init(category: $0.category, count: $0.count, share: $0.share) },
            deepestPickle: deepest.map { .init(record: $0) },
            focusedProject: focused.map { .init(project: $0.key, count: $0.value) },
            distribution: distribution,
            totalCount: total
        )
    }

    static func usageSummary(
        in snapshot: PickyHubStatisticsSnapshot,
        filter: PickyHubStatisticsFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PickyHubUsageSummary {
        let start = filter.period.startDate(now: now, calendar: calendar)
        let startDay = start.map(dayString)
        let samples = snapshot.usageSamples.filter { sample in
            if let startDay, sample.day < startDay { return false }
            if let project = filter.project, sample.project != project { return false }
            return true
        }
        var input = 0, output = 0, cache = 0
        var byDay: [String: Int] = [:]
        var byModel: [String: (provider: String, model: String, input: Int, output: Int, cache: Int, lastDay: String)] = [:]
        for sample in samples {
            input += sample.inputTokens
            output += sample.outputTokens
            cache += sample.cacheTokens
            byDay[sample.day, default: 0] += sample.inputTokens + sample.outputTokens + sample.cacheTokens
            let key = "\(sample.provider)/\(sample.model)"
            var entry = byModel[key] ?? (sample.provider, sample.model, 0, 0, 0, sample.day)
            entry.input += sample.inputTokens
            entry.output += sample.outputTokens
            entry.cache += sample.cacheTokens
            entry.lastDay = max(entry.lastDay, sample.day)
            byModel[key] = entry
        }
        let days = byDay.keys.sorted().map { PickyHubUsageDay(day: $0, totalTokens: byDay[$0] ?? 0) }
        let models = byModel.values
            .map { PickyHubModelUsage(provider: $0.provider, model: $0.model, inputTokens: $0.input, outputTokens: $0.output, cacheTokens: $0.cache, lastUsedDay: $0.lastDay) }
            .sorted { $0.totalTokens > $1.totalTokens }
        return PickyHubUsageSummary(totalTokens: input + output + cache, inputTokens: input, outputTokens: output, cacheTokens: cache, days: days, models: models)
    }

    /// Fills the gap days between `start` and `now` with zero so the line chart
    /// keeps a continuous x-axis. Unbounded periods use the observed range.
    static func continuousDays(
        _ days: [PickyHubUsageDay],
        period: PickyHubStatisticsPeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PickyHubUsageDay] {
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.totalTokens) })
        let end: Date = {
            if period == .thisWeek, let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                return calendar.date(byAdding: .day, value: -1, to: interval.end) ?? now
            }
            return calendar.startOfDay(for: now)
        }()
        var start = period.startDate(now: now, calendar: calendar)
        if start == nil {
            guard let first = days.first, let parsed = date(fromDay: first.day, calendar: calendar) else { return days }
            start = parsed
        }
        guard var cursor = start, cursor <= end else { return days }
        var result: [PickyHubUsageDay] = []
        while cursor <= end {
            let key = dayString(cursor)
            result.append(PickyHubUsageDay(day: key, totalTokens: byDay[key] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private static func chartIndex(_ category: PickyHubWorkCategory) -> Int {
        PickyHubWorkCategory.chartOrder.firstIndex(of: category) ?? .max
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func date(fromDay day: String, calendar: Calendar = .current) -> Date? {
        dayFormatter.date(from: day)
    }
}

/// Compact token formatting (`129.4K`, `1.2M`) shared by dashboard and stats.
enum PickyHubTokenFormatter {
    static func string(_ value: Int) -> String {
        let magnitude = Double(value)
        if magnitude >= 1_000_000 {
            return String(format: "%.1fM", magnitude / 1_000_000)
        }
        if magnitude >= 1_000 {
            return String(format: "%.1fK", magnitude / 1_000)
        }
        return "\(value)"
    }
}
