//
//  PickyMessageStore.swift
//  Picky
//

import Observation

/// Stable identity and leaf-value observation boundary for one message.
@MainActor
@Observable
final class PickyMessageStore {
    let messageID: String
    @ObservationIgnored private var state: PickyProjectionSectionState<PickySessionMessage> = .unavailable
    /// Changes whenever this stable message identity receives a replacement.
    /// Consumers that render its value must read this through `messageState`.
    private(set) var valueRevision = 0

    init(messageID: String) {
        self.messageID = messageID
    }

    var messageState: PickyProjectionSectionState<PickySessionMessage> {
        _ = valueRevision
        return state
    }

    func replace(_ message: PickySessionMessage) {
        precondition(message.id == messageID)
        state = .loaded(message)
        valueRevision += 1
    }

    func markUnavailable() {
        state = .unavailable
        valueRevision += 1
    }
}
