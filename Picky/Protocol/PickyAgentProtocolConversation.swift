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

/// Pi compaction outcome attached to the "Session compacted" system message.
/// `tokensAfter` is Pi's estimate of the context that survived compaction.
struct PickyCompactionResult: Codable, Equatable {
    let tokensBefore: Double
    var tokensAfter: Double? = nil
    var summary: String? = nil
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

    /// Last path segment without the "claude-" / "openai-" vendor prefix.
    /// Shared by the header tooltip and the composer settings chip.
    static func compactModelName(_ rawModel: String) -> String {
        let leaf = rawModel.split(separator: "/").last.map(String.init) ?? rawModel
        for prefix in ["claude-", "openai-"] where leaf.hasPrefix(prefix) {
            return String(leaf.dropFirst(prefix.count))
        }
        return leaf
    }
}

/// Semantic identity of a journal entry agentd wrote on Picky's behalf. The daemon never picks
/// a language: it sends a code (plus any external detail it had to quote) and the app renders
/// the sentence from its own catalog.
enum PickyMessagePresentationCode: String, Codable, Equatable {
    case sessionCancelledByUser
    case agentFailedWithoutDetail
    case sessionCompacted
    case sessionCompactedAfterOverflow
    case sessionCompactionFailed
    case sessionPinnedFromIdlePi
    case userBashFailed
}

/// Values a presentation code needs that only the daemon knows. `detail` is text produced
/// outside Picky (a shell failure, Pi's summarization error) and is shown verbatim.
struct PickyMessagePresentationParams: Codable, Equatable {
    var detail: String? = nil
    /// `nil` when Pi had not reported a token count yet.
    var contextTokens: Double? = nil
    var contextWindowTokens: Double? = nil
}

struct PickyMessagePresentation: Codable, Equatable {
    /// Nil when the daemon sent no usable presentation for this build (unknown code, or a
    /// payload this build cannot read); callers then keep the daemon's English
    /// `text`/`errorMessage`. `params` is nil whenever `code` is.
    let code: PickyMessagePresentationCode?
    let params: PickyMessagePresentationParams?

    init(code: PickyMessagePresentationCode?, params: PickyMessagePresentationParams? = nil) {
        self.code = code
        self.params = params
    }

    private enum CodingKeys: String, CodingKey { case code, params }

    /// Codes whose sentence is built around a string only the daemon has. Without it the catalog
    /// copy would render with a hole where the cause belongs, so the presentation is unusable.
    /// Mirrors the required `params` of `PickyMessagePresentationSchema` in agentd/src/protocol.ts.
    private static func requiresDetail(_ code: PickyMessagePresentationCode) -> Bool {
        switch code {
        case .userBashFailed, .sessionCompactionFailed:
            return true
        case .sessionCancelledByUser, .agentFailedWithoutDetail, .sessionCompacted,
             .sessionCompactedAfterOverflow, .sessionPinnedFromIdlePi:
            return false
        }
    }

    /// Never throws, and never keeps half of a presentation: anything the daemon's own schema
    /// would reject (a non-object value, an unknown code, missing or malformed `params` for a
    /// code that needs them) decodes as no presentation at all, exactly like the TypeScript
    /// `.catch(undefined)`. A malformed presentation must not make the whole message — and with
    /// it the session snapshot — undecodable, and a surviving code without its detail would
    /// replace the daemon's English fallback with a sentence that has a blank where the cause is.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let rawCode = try? container.decodeIfPresent(String.self, forKey: .code),
              let decodedCode = PickyMessagePresentationCode(rawValue: rawCode)
        else {
            code = nil
            params = nil
            return
        }

        // A missing `params` key is normal: most codes carry none. Only a key that is present
        // and unreadable is evidence that this build cannot trust the payload, so the two are
        // kept apart here. A `null` reads as "no params", matching the daemon's schema, which
        // ignores the key entirely for codes that declare none.
        var decodedParams: PickyMessagePresentationParams?
        if container.contains(.params), (try? container.decodeNil(forKey: .params)) == false {
            guard let parsed = try? container.decode(PickyMessagePresentationParams.self, forKey: .params) else {
                code = nil
                params = nil
                return
            }
            decodedParams = parsed
        }

        guard !(Self.requiresDetail(decodedCode) && decodedParams?.detail == nil) else {
            code = nil
            params = nil
            return
        }
        code = decodedCode
        params = decodedParams
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(code?.rawValue, forKey: .code)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

struct PickyToolImage: Codable, Equatable {
    var toolCallId: String? = nil
    let toolName: String
    let path: String
    var mimeType: String? = nil
}

/// One "label · answer" line agentd records on an answered question message.
struct PickyQuestionAnswerRow: Codable, Equatable {
    let label: String
    let value: String
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
    var compaction: PickyCompactionResult? = nil
    var subagentInvocation: PickySubagentInvocation? = nil
    /// Count of image attachments that travelled with this user_text via the
    /// structured context channel (PTT / QuickInput screenshots). Nil for
    /// messages that have no attachments or for non-user kinds.
    var attachedImagesCount: Int? = nil
    /// Image a tool handed to the model (Pi `read` on an image file). Rides on a
    /// `system` message; the HUD loads the local file, the journal keeps only the path.
    var toolImage: PickyToolImage? = nil
    /// Set only on entries Picky itself authored; see `PickyMessagePresentationCode`.
    var presentation: PickyMessagePresentation? = nil
    /// What the user answered on an `agentQuestion`, shown in the collapsed bubble.
    var answerRows: [PickyQuestionAnswerRow]? = nil
}

extension PickySessionMessage {
    /// Markdown content that the user can pop open in the report viewer. Originally
    /// limited to `.agentText` (the latest agent reply), this now also covers user
    /// requests and system messages so any text-bearing bubble can be expanded into
    /// the larger markdown view from the conversation card.
    var openAsReportMarkdown: String? {
        if toolImage != nil { return nil }
        switch kind {
        case .agentText, .userText, .system:
            if let compactSummaryReportMarkdown { return compactSummaryReportMarkdown }
            let source = localizedPresentationText ?? text ?? ""
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
