import CoreGraphics
import Foundation

struct PickyInteractionState: Equatable, Codable {
    var input: PickyInputPhase
    var output: PickyOutputPhase
    var pointer: PickyPointerPhase
    var overlay: PickyOverlayPhase
    var pendingTextInputs: [UUID: PickyTextInputState]
    var pendingVoiceInputs: [UUID: PickyVoiceInputState]
    var contextOwnership: [String: PickyContextOwner]
    var lastDisplayMessage: PickyDisplayMessage?

    init(
        input: PickyInputPhase = .idle,
        output: PickyOutputPhase = .idle,
        pointer: PickyPointerPhase = .idle,
        overlay: PickyOverlayPhase = .hidden,
        pendingTextInputs: [UUID: PickyTextInputState] = [:],
        pendingVoiceInputs: [UUID: PickyVoiceInputState] = [:],
        contextOwnership: [String: PickyContextOwner] = [:],
        lastDisplayMessage: PickyDisplayMessage? = nil
    ) {
        self.input = input
        self.output = output
        self.pointer = pointer
        self.overlay = overlay
        self.pendingTextInputs = pendingTextInputs
        self.pendingVoiceInputs = pendingVoiceInputs
        self.contextOwnership = contextOwnership
        self.lastDisplayMessage = lastDisplayMessage
    }
}

enum PickyInputPhase: Equatable, Codable {
    case idle
    case voiceListening(inputID: UUID, targetSessionID: String?)
    case voiceFinalizing(inputID: UUID, targetSessionID: String?, transcriptPreview: String?)
    case voiceSubmitting(inputID: UUID, targetSessionID: String?, transcript: String)
    case textSubmitting(inputID: UUID, text: String)
}

enum PickyOutputPhase: Equatable, Codable {
    case idle
    case waitingForAgent(inputID: UUID?, contextID: String?, promptPreview: String?)
    case showingTextReply(contextID: String, text: String, minimumDisplayTimerID: UUID?, minimumDisplayUntil: Date?)
    case speaking(contextID: String?, speechID: UUID, text: String, minimumDisplayTimerID: UUID?, minimumDisplayUntil: Date?, finishPending: Bool)
    case suppressedReply(contextID: String, text: String, reason: PickyReplySuppressionReason, minimumDisplayTimerID: UUID?, minimumDisplayUntil: Date?)
}

enum PickyPointerPhase: Equatable, Codable {
    case idle
    case requested(PickyPointerTarget)
    case navigating(PickyPointerTarget)
    case pointing(PickyPointerTarget)
    case returning(PickyPointerTarget)

    var target: PickyPointerTarget? {
        switch self {
        case .idle: nil
        case .requested(let target), .navigating(let target), .pointing(let target), .returning(let target): target
        }
    }
}

enum PickyOverlayPhase: Equatable, Codable {
    case hidden
    case visible(reason: Set<PickyOverlayReason>)
    case hiding(timerID: UUID, reason: PickyOverlayReason)
}

struct PickyTextInputState: Equatable, Codable {
    var text: String
    var contextID: String?
    var source: PickyInteractionSource

    init(text: String, contextID: String? = nil, source: PickyInteractionSource = .text) {
        self.text = text
        self.contextID = contextID
        self.source = source
    }
}

struct PickyVoiceInputState: Equatable, Codable {
    var transcript: String?
    var targetSessionID: String?
    var contextID: String?

    init(transcript: String? = nil, targetSessionID: String? = nil, contextID: String? = nil) {
        self.transcript = transcript
        self.targetSessionID = targetSessionID
        self.contextID = contextID
    }
}

enum PickyContextOwner: Equatable, Codable {
    case text(inputID: UUID)
    case quickInputText(inputID: UUID)
    case voice(inputID: UUID)
    case metadataText
    case metadataVoice
    case system
    case unknown

    var isVoiceOwned: Bool {
        switch self {
        case .voice, .metadataVoice:
            true
        case .text, .quickInputText, .metadataText, .system, .unknown:
            false
        }
    }

    var isTextOwned: Bool {
        switch self {
        case .text, .quickInputText, .metadataText:
            true
        case .voice, .metadataVoice, .system, .unknown:
            false
        }
    }

    var usesCursorResponsePresentation: Bool {
        switch self {
        case .quickInputText:
            true
        case .text, .voice, .metadataText, .metadataVoice, .system, .unknown:
            false
        }
    }
}

struct PickyDisplayMessage: Equatable, Codable, Identifiable {
    let id: String
    let contextID: String?
    let text: String
    let source: PickyDisplaySource
    let updatedAt: Date
}

enum PickyDisplaySource: String, Equatable, Codable {
    case textReply
    case voiceReply
    case passiveSummary
    case sideCompletion
    case suppressed
}

struct PickyPointerTarget: Equatable, Codable, Identifiable {
    let id: String
    let source: PickyPointerSource
    let screenLocation: CGPoint
    let displayFrame: CGRect
    let bubbleText: String?
    let duration: TimeInterval
    let targetFrame: CGRect?
    let highlightKind: PickyDetectedHighlightKind

    init(
        id: String,
        source: PickyPointerSource = .agent,
        screenLocation: CGPoint,
        displayFrame: CGRect,
        bubbleText: String? = nil,
        duration: TimeInterval,
        targetFrame: CGRect? = nil,
        highlightKind: PickyDetectedHighlightKind = .screenElement
    ) {
        self.id = id
        self.source = source
        self.screenLocation = screenLocation
        self.displayFrame = displayFrame
        self.bubbleText = bubbleText
        self.duration = duration
        self.targetFrame = targetFrame
        self.highlightKind = highlightKind
    }
}

enum PickyPointerSource: String, Equatable, Codable {
    case agent
    case system
}

enum PickyPointerCancelReason: String, Equatable, Codable {
    case superseded
    case userInput
    case hidden
    case failed
    case unknown
}

enum PickyReplySuppressionReason: String, Equatable, Codable {
    case activeVoiceInput
    case staleContext
    case sideCompletionPolicy
    case unknown
}

enum PickyOverlayReason: String, Equatable, Codable, Hashable {
    case cursorPreferenceEnabled
    case activeVoiceInput
    case waitingForVoiceResponse
    case speakingResponse
    case activePointerAnimation
    case transientPointerDisplay
}

enum PickySpeechStopReason: String, Equatable, Codable {
    case superseded
    case userInterrupted
    case failed
    case unknown
}
