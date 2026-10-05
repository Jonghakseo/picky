//
//  PickyUsageLimitsModels.swift
//  Picky
//
//  Wire models for `getUsageLimits` -> `usageLimitsResult` plus the shared
//  presentation rules used by the Hub cards, the menu bar items, and the HUD
//  context popover, so all three describe a limit the same way.
//

import AppKit
import Foundation
import SwiftUI

enum PickyUsageLimitsProviderID: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openaiCodex = "openai-codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Claude"
        case .openaiCodex: "ChatGPT"
        }
    }

    /// Template SVG in the asset catalog.
    var logoAssetName: String {
        switch self {
        case .anthropic: "ProviderClaudeLogo"
        case .openaiCodex: "ProviderOpenAILogo"
        }
    }

    var statusURL: URL {
        switch self {
        case .anthropic: URL(string: "https://status.claude.com")!
        case .openaiCodex: URL(string: "https://status.openai.com")!
        }
    }

    var dashboardURL: URL {
        switch self {
        case .anthropic: URL(string: "https://claude.ai/settings/usage")!
        case .openaiCodex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }

    /// Subscription whose limits a model run counts against. Model ids arrive
    /// bare (`claude-opus-4-5`) or provider-qualified (`openai-codex/gpt-5.1`).
    static func forModel(_ rawModel: String?) -> PickyUsageLimitsProviderID? {
        guard let rawModel else { return nil }
        let lowered = rawModel.lowercased()
        let parts = lowered.split(separator: "/").map(String.init)
        if parts.count > 1, let provider = parts.first {
            if provider == "anthropic" { return .anthropic }
            if provider == "openai-codex" { return .openaiCodex }
            return nil
        }
        let leaf = parts.last ?? lowered
        if leaf.hasPrefix("claude") { return .anthropic }
        if leaf.hasPrefix("gpt") || leaf.contains("codex") { return .openaiCodex }
        return nil
    }
}

struct PickyUsageLimitWindow: Codable, Equatable {
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Int { Int(max(0, min(100, 100 - usedPercent)).rounded()) }
    var remainingFraction: Double { Double(remainingPercent) / 100 }
}

struct PickyUsageLimitResets: Codable, Equatable {
    let available: Int
    let nextExpiresAt: Date?
}

struct PickyUsageLimitsProvider: Codable, Equatable, Identifiable {
    let provider: PickyUsageLimitsProviderID
    let plan: String?
    /// Last successful check.
    let checkedAt: Date?
    /// Present when the latest check failed; the windows then hold the last known values.
    let errorMessage: String?
    let session: PickyUsageLimitWindow?
    let weekly: PickyUsageLimitWindow?
    let resets: PickyUsageLimitResets?

    var id: String { provider.rawValue }
    var isStale: Bool { errorMessage != nil }
}

struct PickyUsageLimitsSnapshot: Codable, Equatable {
    let checkedAt: Date
    let providers: [PickyUsageLimitsProvider]

    func provider(_ id: PickyUsageLimitsProviderID) -> PickyUsageLimitsProvider? {
        providers.first { $0.provider == id }
    }
}

/// Reply to `getUsageLimits`. `snapshot` is present only on success.
struct PickyUsageLimitsResultEvent: Decodable, Equatable {
    let commandId: String
    let ok: Bool
    let errorMessage: String?
    let snapshot: PickyUsageLimitsSnapshot?
}

// MARK: - Presentation

enum PickyUsageLimitWindowKind {
    case session, weekly

    var length: TimeInterval {
        switch self {
        case .session: 5 * 3600
        case .weekly: 7 * 24 * 3600
        }
    }
}

/// Where the remaining share would be if usage were spread evenly until the reset.
struct PickyUsageLimitPace: Equatable {
    /// Even-pace remaining share, 0...1.
    let expectedRemainingFraction: Double
    /// Remaining share trails even pace by more than the tolerance.
    let isAhead: Bool

    /// A few points of slack keep the warning from flickering on normal bursts.
    static let tolerancePercent = 5.0

    init?(window: PickyUsageLimitWindow?, kind: PickyUsageLimitWindowKind, now: Date) {
        guard let window, let resetsAt = window.resetsAt else { return nil }
        let left = resetsAt.timeIntervalSince(now)
        guard left > 0, left <= kind.length else { return nil }
        expectedRemainingFraction = left / kind.length
        isAhead = Double(window.remainingPercent) < expectedRemainingFraction * 100 - Self.tolerancePercent
    }
}

enum PickyUsageLimitTone: Equatable {
    case normal, warning, danger, unknown

    /// Remaining share drives the tone: 30% or less warns, 10% or less is critical.
    init(window: PickyUsageLimitWindow?) {
        guard let window else { self = .unknown; return }
        switch window.remainingPercent {
        case ...10: self = .danger
        case ...30: self = .warning
        default: self = .normal
        }
    }
}

enum PickyUsageResetDeadlineTone: Equatable {
    case later, withinWeek, within48Hours

    init(expiresAt: Date, now: Date) {
        let interval = expiresAt.timeIntervalSince(now)
        if interval <= 48 * 3600 { self = .within48Hours }
        else if interval <= 7 * 24 * 3600 { self = .withinWeek }
        else { self = .later }
    }
}

enum PickyUsageLimitsPresentation {
    static func remainingText(_ window: PickyUsageLimitWindow?) -> String {
        guard let window else { return "—" }
        return L10n.t("usageLimits.remaining", window.remainingPercent)
    }

    static func shortRemainingText(_ window: PickyUsageLimitWindow?) -> String {
        guard let window else { return "—" }
        return "\(window.remainingPercent)%"
    }

    /// "27분 후 초기화" / "Resets in 27m". Unknown reset times say so instead of guessing.
    static func resetText(_ window: PickyUsageLimitWindow?, now: Date) -> String {
        guard let window else { return L10n.t("usageLimits.noData") }
        guard let resetsAt = window.resetsAt else { return L10n.t("usageLimits.reset.unknown") }
        return L10n.t("usageLimits.reset.in", durationText(until: resetsAt, now: now))
    }

    static func durationText(until date: Date, now: Date) -> String {
        let totalMinutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? L10n.t("usageLimits.duration.daysHours", days, hours) : L10n.t("usageLimits.duration.days", days)
        }
        if hours > 0 {
            return minutes > 0 ? L10n.t("usageLimits.duration.hoursMinutes", hours, minutes) : L10n.t("usageLimits.duration.hours", hours)
        }
        return L10n.t("usageLimits.duration.minutes", minutes)
    }

    static func resetsText(_ resets: PickyUsageLimitResets?) -> String {
        guard let resets else { return L10n.t("usageLimits.noData") }
        return resets.available > 0 ? L10n.t("usageLimits.resets.available", resets.available) : L10n.t("usageLimits.resets.none")
    }

    static func checkedText(_ provider: PickyUsageLimitsProvider, now: Date) -> String {
        guard let checkedAt = provider.checkedAt else { return L10n.t("usageLimits.checked.never") }
        let minutes = Int(now.timeIntervalSince(checkedAt) / 60)
        if provider.isStale {
            return minutes < 1 ? L10n.t("usageLimits.checked.staleJustNow") : L10n.t("usageLimits.checked.staleMinutes", minutes)
        }
        return minutes < 1 ? L10n.t("usageLimits.checked.justNow") : L10n.t("usageLimits.checked.minutes", minutes)
    }
}
