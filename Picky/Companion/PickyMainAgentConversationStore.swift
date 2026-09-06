//
//  PickyMainAgentConversationStore.swift
//  Picky
//
//  Owner of the main Picky agent's transcript, Pi session location, and model
//  option list as reported by picky-agentd. Pure state: CompanionManager applies
//  daemon events here and subscribes for side effects (Quick Input transcript).
//

import Combine
import Foundation

@MainActor
final class PickyMainAgentConversationStore: ObservableObject {
    static let messageRetention = 100

    @Published private(set) var messages: [PickyMainAgentMessage] = []
    /// Both fields are nil until the daemon has started a real Pi session for
    /// the main agent. Drives "Open in Pi" / "Copy resume command".
    @Published private(set) var sessionInfo = PickyMainAgentSessionInfo()
    @Published private(set) var modelOptions: [PickyMainAgentModelOption] = []
    @Published private(set) var isLoadingModelOptions = false

    func replaceMessages(_ snapshot: [PickyMainAgentMessage]) {
        messages = Array(snapshot.suffix(Self.messageRetention))
    }

    func appendMessage(_ message: PickyMainAgentMessage) {
        messages = Array((messages + [message]).suffix(Self.messageRetention))
    }

    func clearMessages() {
        messages = []
    }

    func updateSessionInfo(sessionFilePath: String?, cwd: String?) {
        sessionInfo = PickyMainAgentSessionInfo(sessionFilePath: sessionFilePath, cwd: cwd)
    }

    func beginLoadingModelOptions() {
        isLoadingModelOptions = true
    }

    func applyModelOptions(_ options: [PickyMainAgentModelOption]) {
        modelOptions = options
        isLoadingModelOptions = false
    }

    func failLoadingModelOptions() {
        isLoadingModelOptions = false
    }
}
