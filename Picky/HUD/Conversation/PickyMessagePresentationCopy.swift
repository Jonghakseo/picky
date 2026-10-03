//
//  PickyMessagePresentationCopy.swift
//  Picky
//
//  Turns the semantic codes agentd attaches to its own journal entries into
//  catalog copy. The daemon writes English text for the CLI and for readers
//  that predate a code; Picky renders this instead whenever a code is present.
//

import Foundation

extension PickySessionMessage {
    /// Localized body for a journal entry Picky authored. Nil when the daemon sent no code, or
    /// one this build does not know, in which case the daemon's English text stands.
    var localizedPresentationText: String? {
        guard let code = presentation?.code else { return nil }
        switch code {
        case .sessionCancelledByUser:
            return L10n.t("hud.message.cancelledByUser")
        case .agentFailedWithoutDetail:
            return L10n.t("hud.message.agentFailed")
        case .sessionPinnedFromIdlePi:
            return L10n.t("hud.message.pinnedFromIdlePi")
        case .userBashFailed:
            return L10n.t("hud.message.bashFailed", presentation?.params?.detail ?? "")
        case .sessionCompacted, .sessionCompactedAfterOverflow:
            // Normally drawn by the compaction bubble, which owns its own title.
            return L10n.t("hud.compact.done.title")
        case .sessionCompactionFailed:
            let detail = localizedCompactFailureDetail ?? ""
            return "\(L10n.t("hud.compact.failed.title"))\n\n\(detail)"
        }
    }

    /// Body of the compaction-failure bubble: the summarizer's own words, then what that means
    /// for the conversation. Nil when the daemon sent no typed parameters for this failure.
    var localizedCompactFailureDetail: String? {
        guard presentation?.code == .sessionCompactionFailed, let params = presentation?.params else { return nil }
        let detail = params.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let outcome = [L10n.t("hud.compact.failed.notReduced"), Self.localizedUsageSentence(params)]
            .compactMap { $0 }
            .joined(separator: " ")
        return detail.isEmpty ? outcome : "\(detail)\n\n\(outcome)"
    }

    private static func localizedUsageSentence(_ params: PickyMessagePresentationParams) -> String? {
        guard let contextWindow = params.contextWindowTokens else { return nil }
        return L10n.t(
            "hud.compact.failed.usage",
            localizedTokenCount(params.contextTokens),
            localizedTokenCount(contextWindow)
        )
    }

    private static func localizedTokenCount(_ value: Double?) -> String {
        guard let value else { return L10n.t("hud.message.tokenCount.unknown") }
        return Int(value.rounded()).formatted(.number.locale(LocaleManager.nonisolatedEffectiveLocale))
    }
}
