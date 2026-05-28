//
//  PickyFullscreenAssistantRunResolver.swift
//  Picky
//
//  Resolves the assistant run metadata shown in fullscreen without requiring
//  an actively running turn.
//

import Foundation

enum PickyFullscreenAssistantRunResolver {
    static func effectiveAssistantRun(
        currentAssistantRun: PickyAssistantRunMetadata?,
        messages: [PickySessionMessage]
    ) -> PickyAssistantRunMetadata? {
        currentAssistantRun ?? messages.reversed().compactMap(\.assistantRun).first
    }

    static func effectiveAssistantRun(for session: PickySessionListViewModel.SessionCard) -> PickyAssistantRunMetadata? {
        effectiveAssistantRun(
            currentAssistantRun: session.currentAssistantRun,
            messages: session.messages
        )
    }
}
