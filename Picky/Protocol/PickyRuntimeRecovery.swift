import Foundation

/// Automatic restart of a Pickle runtime the daemon could not tear down.
struct PickyRuntimeRecovery: Codable, Equatable {
    enum Phase: String, Codable, Equatable {
        /// A fresh runtime is being attached; input is rejected until it finishes.
        case restarting
        /// The restart finished; work in flight before it did not continue.
        case restarted
        /// No runtime could be attached; duplicating the Pickle continues it.
        case failed
    }

    var phase: Phase
    var updatedAt: Date
}
