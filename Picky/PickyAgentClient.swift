//
//  PickyAgentClient.swift
//  Picky
//
//  Local-first abstraction for submitting neutral desktop context to the
//  Picky agent backend. Phase 1 provides an in-process stub so the macOS
//  shell no longer depends on any hosted chat API.
//

import Foundation

struct PickyAgentSubmission: Equatable {
    let transcript: String
    let context: PickyContextPacket
}

protocol PickyAgentClient {
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt
}

struct PickyAgentSubmissionReceipt: Equatable {
    let sessionID: String
    let message: String
}

struct LocalStubPickyAgentClient: PickyAgentClient {
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        let stableSessionInput = [
            submission.context.source,
            submission.context.transcript,
            submission.context.activeApplication?.bundleIdentifier ?? "unknown-app",
            submission.context.activeWindow?.title ?? "unknown-window"
        ].joined(separator: "|")

        return PickyAgentSubmissionReceipt(
            sessionID: "local-stub-\(abs(stableSessionInput.hashValue))",
            message: "Task captured locally. picky-agentd integration will run this through Pi in a later phase."
        )
    }
}
