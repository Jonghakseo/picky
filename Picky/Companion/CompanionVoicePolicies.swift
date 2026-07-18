//
//  CompanionVoicePolicies.swift
//  Picky
//
//  Pure voice presentation and provider-reload policies.
//

import Foundation

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum CompanionVoicePromptBubbleState: Equatable {
    private static let recognizedPromptPreviewCharacterLimit = 280

    case hidden
    case recognizing
    case recognized(String)

    var isVisible: Bool {
        if case .recognized = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .hidden, .recognizing:
            return ""
        case .recognized(let prompt):
            return Self.truncatedPreviewText(for: prompt)
        }
    }

    private static func truncatedPreviewText(for prompt: String) -> String {
        guard prompt.count > recognizedPromptPreviewCharacterLimit else { return prompt }

        let previewEndIndex = prompt.index(prompt.startIndex, offsetBy: recognizedPromptPreviewCharacterLimit)
        return String(prompt[..<previewEndIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

struct CompanionVoicePresentationState: Equatable {
    let voiceState: CompanionVoiceState
    let promptBubbleState: CompanionVoicePromptBubbleState
}

/// The subset of persisted settings that changes the live STT/TTS providers.
/// Settings saves are global, so unrelated edits (for example the main model)
/// must not rebuild the voice stack or interrupt an active cursor reply.
struct PickyVoiceProviderSettings: Equatable {
    let sttProvider: PickyVoiceProviderSelection
    let ttsProvider: PickyVoiceProviderSelection
    let ttsEnabled: Bool
    let edgeTTSVoice: String
    let azureOpenAIEndpoint: String
    let azureOpenAIAPIKey: String
    let azureOpenAITTSEndpoint: String
    let azureOpenAITTSAPIKey: String
    let azureOpenAITTSVoice: String
    let azureSTTPreferredLanguage: String
    let openAITTSAPIKey: String
    let openAITTSVoice: String
    let openAITTSModel: String
    let openAISTTAPIKey: String
    let openAISTTModel: String
    let openAISTTPreferredLanguage: String
    let openAITTSBaseURL: String
    let openAISTTBaseURL: String
    let elevenLabsTTSAPIKey: String
    let elevenLabsTTSVoiceID: String
    let elevenLabsTTSModel: String
    let elevenLabsTTSOutputFormat: String
    let elevenLabsTTSBaseURL: String
    let elevenLabsSTTAPIKey: String
    let elevenLabsSTTModel: String
    let elevenLabsSTTLanguage: String

    init(_ settings: PickySettings) {
        sttProvider = settings.sttProvider
        ttsProvider = settings.ttsProvider
        ttsEnabled = settings.ttsEnabled
        edgeTTSVoice = settings.edgeTTSVoice
        azureOpenAIEndpoint = settings.azureOpenAIEndpoint
        azureOpenAIAPIKey = settings.azureOpenAIAPIKey
        azureOpenAITTSEndpoint = settings.azureOpenAITTSEndpoint
        azureOpenAITTSAPIKey = settings.azureOpenAITTSAPIKey
        azureOpenAITTSVoice = settings.azureOpenAITTSVoice
        azureSTTPreferredLanguage = settings.azureSTTPreferredLanguage
        openAITTSAPIKey = settings.openAITTSAPIKey
        openAITTSVoice = settings.openAITTSVoice
        openAITTSModel = settings.openAITTSModel
        openAISTTAPIKey = settings.openAISTTAPIKey
        openAISTTModel = settings.openAISTTModel
        openAISTTPreferredLanguage = settings.openAISTTPreferredLanguage
        openAITTSBaseURL = settings.openAITTSBaseURL
        openAISTTBaseURL = settings.openAISTTBaseURL
        elevenLabsTTSAPIKey = settings.elevenLabsTTSAPIKey
        elevenLabsTTSVoiceID = settings.elevenLabsTTSVoiceID
        elevenLabsTTSModel = settings.elevenLabsTTSModel
        elevenLabsTTSOutputFormat = settings.elevenLabsTTSOutputFormat
        elevenLabsTTSBaseURL = settings.elevenLabsTTSBaseURL
        elevenLabsSTTAPIKey = settings.elevenLabsSTTAPIKey
        elevenLabsSTTModel = settings.elevenLabsSTTModel
        elevenLabsSTTLanguage = settings.elevenLabsSTTLanguage
    }
}

enum CompanionVoicePresentationReducer {
    static func reduce(
        currentVoiceState: CompanionVoiceState,
        isKeyboardRecording: Bool,
        isMicrophoneRecording: Bool,
        isFinalizingTranscript: Bool,
        isPreparingToRecord: Bool,
        isShortcutHeld: Bool,
        isAwaitingAgentResponse: Bool,
        recognizedPrompt: String?
    ) -> CompanionVoicePresentationState {
        let trimmedPrompt = recognizedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let promptBubbleState: CompanionVoicePromptBubbleState
        if isFinalizingTranscript {
            promptBubbleState = trimmedPrompt.isEmpty ? .hidden : .recognized(trimmedPrompt)
        } else if isAwaitingAgentResponse {
            promptBubbleState = trimmedPrompt.isEmpty ? .hidden : .recognized(trimmedPrompt)
        } else {
            promptBubbleState = .hidden
        }

        if currentVoiceState == .responding {
            return CompanionVoicePresentationState(voiceState: .responding, promptBubbleState: .hidden)
        }
        if isShortcutHeld || isKeyboardRecording || isMicrophoneRecording {
            return CompanionVoicePresentationState(voiceState: .listening, promptBubbleState: promptBubbleState)
        }
        if isFinalizingTranscript || isPreparingToRecord {
            return CompanionVoicePresentationState(voiceState: .processing, promptBubbleState: promptBubbleState)
        }
        if isAwaitingAgentResponse {
            return CompanionVoicePresentationState(voiceState: .processing, promptBubbleState: promptBubbleState)
        }
        return CompanionVoicePresentationState(voiceState: .idle, promptBubbleState: .hidden)
    }
}
