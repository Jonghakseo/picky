//
//  PickyAgentProtocolConversation.swift
//  Picky
//
//  Codable app-daemon conversation protocol models.
//

import Foundation

enum PickyMessageOrigin: String, Codable, Equatable {
    case user
    case mainAgent = "main_agent"
    case piExtension = "pi_extension"
}

enum PickySessionMessageKind: String, Codable, Equatable {
    case userText = "user_text"
    case agentText = "agent_text"
    case agentThinking = "agent_thinking"
    case agentQuestion = "agent_question"
    case agentError = "agent_error"
    case agentActivity = "agent_activity"
    case commandReceipt = "command_receipt"
    case subagentInvocation = "subagent_invocation"
    case system

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .system
    }
}

enum PickyCommandReceiptStatus: String, Codable, Equatable {
    case submitted
    case failed
}

struct PickyCommandReceipt: Codable, Equatable {
    let command: String
    let status: PickyCommandReceiptStatus
    let detail: String?
}

struct PickyAssistantRunMetadata: Codable, Equatable {
    var model: String?
    var thinkingLevel: PickyMainAgentThinkingLevel?

    var displayText: String? {
        let parts = [model.map(Self.compactModelName), thinkingLevel?.rawValue]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private static func compactModelName(_ rawModel: String) -> String {
        let leaf = rawModel.split(separator: "/").last.map(String.init) ?? rawModel
        for prefix in ["claude-", "openai-"] where leaf.hasPrefix(prefix) {
            return String(leaf.dropFirst(prefix.count))
        }
        return leaf
    }
}

struct PickySessionMessage: Codable, Equatable, Identifiable {
    let id: String
    let kind: PickySessionMessageKind
    let createdAt: Date
    let originatedBy: PickyMessageOrigin?
    let text: String?
    let question: PickyExtensionUiRequest?
    let cancelledAt: Date?
    let activitySnapshot: PickyActivitySummary?
    var assistantRun: PickyAssistantRunMetadata? = nil
    let errorContext: String?
    let errorMessage: String?
    var notifyType: PickyExtensionNotifyType? = nil
    /// Pi's `customType` for role="custom" extension messages. Any tagged
    /// message renders as a labeled, collapsible bubble instead of a plain
    /// system one. Nil for every message Pi did not tag.
    var customType: String? = nil
    var commandReceipt: PickyCommandReceipt? = nil
    var subagentInvocation: PickySubagentInvocation? = nil
    /// Count of image attachments that travelled with this user_text via the
    /// structured context channel (PTT / QuickInput screenshots). Nil for
    /// messages that have no attachments or for non-user kinds.
    var attachedImagesCount: Int? = nil
}

extension PickySessionMessage {
    /// Markdown content that the user can pop open in the report viewer. Originally
    /// limited to `.agentText` (the latest agent reply), this now also covers user
    /// requests and system messages so any text-bearing bubble can be expanded into
    /// the larger markdown view from the conversation card.
    var openAsReportMarkdown: String? {
        switch kind {
        case .agentText, .userText, .system:
            let source = text ?? ""
            let reportText = notifyType == nil ? source : PickyAnsiEscapeSanitizer.stripped(source)
            let trimmed = reportText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .subagentInvocation:
            return nil
        default:
            return nil
        }
    }
}

enum PickyAnsiEscapeSanitizer {
    static func stripped(_ value: String) -> String {
        var output = String.UnicodeScalarView()
        let scalars = Array(value.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.value == 0x1B else {
                output.append(scalar)
                index += 1
                continue
            }

            guard index + 1 < scalars.count else { break }
            let next = scalars[index + 1]
            if next == "[" {
                index += 2
                while index < scalars.count {
                    let value = scalars[index].value
                    index += 1
                    if value >= 0x40 && value <= 0x7E { break }
                }
                continue
            }
            if next == "]" {
                index += 2
                while index < scalars.count {
                    if scalars[index].value == 0x07 {
                        index += 1
                        break
                    }
                    if scalars[index].value == 0x1B,
                       index + 1 < scalars.count,
                       scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }
            if next.value >= 0x40 && next.value <= 0x5F {
                index += 2
                continue
            }

            output.append(scalar)
            index += 1
        }

        return String(output)
    }
}
