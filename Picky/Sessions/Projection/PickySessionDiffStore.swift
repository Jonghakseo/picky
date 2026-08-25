//
//  PickySessionDiffStore.swift
//  Picky
//

import Combine

/// Per-session owner for the on-demand git-diff utility panel. It keeps diff
/// responses from invalidating unrelated session cards through the v1 façade.
@MainActor
final class PickySessionDiffStore: ObservableObject {
    @Published private(set) var state = PickySessionDiffState()

    func replace(_ state: PickySessionDiffState) {
        guard self.state != state else { return }
        self.state = state
    }
}
