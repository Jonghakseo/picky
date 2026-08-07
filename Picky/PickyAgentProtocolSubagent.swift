//
//  PickyAgentProtocolSubagent.swift
//  Picky
//
//  Codable app-daemon subagent invocation and run protocol models.
//

import Foundation

struct PickySubagentRunsUpdatedPayload: Decodable {
    let sessionId: String
    let runs: [PickySubagentRun]
    let seq: Int
}

enum PickySubagentRunStatus: String, Codable, Equatable {
    case running, done, error
}

struct PickySubagentLastActivity: Codable, Equatable {
    var toolName: String? = nil
    var toolCallCount: Int? = nil
    var lastLine: String? = nil
    var contextTokens: Int? = nil
    var contextUsage: PickyContextUsage? = nil
}

struct PickySubagentInvocationPlan: Codable, Equatable, Identifiable {
    let agent: String
    let task: String

    var id: String { "\(agent):\(task)" }
}

enum PickySubagentInvocationAction: String, Codable, Equatable {
    case run, batch, chain

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .run
    }
}

struct PickySubagentInvocation: Codable, Equatable {
    let invocationId: String
    let action: PickySubagentInvocationAction
    let planned: [PickySubagentInvocationPlan]
    var completed: Bool? = nil
}

struct PickySubagentRun: Codable, Equatable, Identifiable {
    let runId: Int
    let agent: String
    let task: String
    let displayTask: String?
    let status: PickySubagentRunStatus
    let errorClass: String?
    let startedAt: Date?
    let elapsedMs: Double?
    let batchId: String?
    let pipelineId: String?
    let pipelineStepIndex: Int?
    let resultPreview: String?
    var resultText: String? = nil
    let model: String?
    var invocationId: String? = nil
    var lastActivity: PickySubagentLastActivity? = nil

    var id: Int { runId }
}
