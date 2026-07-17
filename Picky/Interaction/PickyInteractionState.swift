import CoreGraphics
import Foundation

struct PickyInteractionState: Equatable, Codable {
    var input: PickyInputPhase
    var output: PickyOutputPhase
    var pointer: PickyPointerPhase
    /// Transient AI visual guidance. Kept separate from pointer animations and user ink.
    var agentAnnotations: [PickyAgentAnnotation]
    var overlay: PickyOverlayPhase
    var pendingTextInputs: [UUID: PickyTextInputState]
    var pendingVoiceInputs: [UUID: PickyVoiceInputState]
    var contextOwnership: [String: PickyContextOwner]
    var queuedSpeechReplies: [PickyQueuedSpeechReply]
    var lastDisplayMessage: PickyDisplayMessage?
    /// sessionID -> (inputID, contextID) captured at `agentSubmissionAccepted` so a later
    /// `.sessionTerminated` can release the matching `.waitingForAgent` output even when
    /// no `quickReply` ever arrives (HUD abort / runtime cancel). Cleared on `quickReply`
    /// for the same sessionID and on `.sessionTerminated`. Codable with a default so older
    /// on-disk journals stay loadable.
    var pendingAgentRequestsBySession: [String: PickyPendingAgentRequest]

    init(
        input: PickyInputPhase = .idle,
        output: PickyOutputPhase = .idle,
        pointer: PickyPointerPhase = .idle,
        agentAnnotations: [PickyAgentAnnotation] = [],
        overlay: PickyOverlayPhase = .hidden,
        pendingTextInputs: [UUID: PickyTextInputState] = [:],
        pendingVoiceInputs: [UUID: PickyVoiceInputState] = [:],
        contextOwnership: [String: PickyContextOwner] = [:],
        queuedSpeechReplies: [PickyQueuedSpeechReply] = [],
        lastDisplayMessage: PickyDisplayMessage? = nil,
        pendingAgentRequestsBySession: [String: PickyPendingAgentRequest] = [:]
    ) {
        self.input = input
        self.output = output
        self.pointer = pointer
        self.agentAnnotations = agentAnnotations
        self.overlay = overlay
        self.pendingTextInputs = pendingTextInputs
        self.pendingVoiceInputs = pendingVoiceInputs
        self.contextOwnership = contextOwnership
        self.queuedSpeechReplies = queuedSpeechReplies
        self.lastDisplayMessage = lastDisplayMessage
        self.pendingAgentRequestsBySession = pendingAgentRequestsBySession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try container.decode(PickyInputPhase.self, forKey: .input)
        self.output = try container.decode(PickyOutputPhase.self, forKey: .output)
        self.pointer = try container.decode(PickyPointerPhase.self, forKey: .pointer)
        self.agentAnnotations = try container.decodeIfPresent([PickyAgentAnnotation].self, forKey: .agentAnnotations) ?? []
        self.overlay = try container.decode(PickyOverlayPhase.self, forKey: .overlay)
        self.pendingTextInputs = try container.decode([UUID: PickyTextInputState].self, forKey: .pendingTextInputs)
        self.pendingVoiceInputs = try container.decode([UUID: PickyVoiceInputState].self, forKey: .pendingVoiceInputs)
        self.contextOwnership = try container.decode([String: PickyContextOwner].self, forKey: .contextOwnership)
        self.queuedSpeechReplies = try container.decode([PickyQueuedSpeechReply].self, forKey: .queuedSpeechReplies)
        self.lastDisplayMessage = try container.decodeIfPresent(PickyDisplayMessage.self, forKey: .lastDisplayMessage)
        // Older journals do not encode this field; treat absence as an empty map.
        self.pendingAgentRequestsBySession = try container.decodeIfPresent([String: PickyPendingAgentRequest].self, forKey: .pendingAgentRequestsBySession) ?? [:]
    }
}

struct PickyPendingAgentRequest: Equatable, Codable {
    let inputID: UUID?
    let contextID: String?
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

struct PickyQueuedSpeechReply: Equatable, Codable {
    let contextID: String
    let text: String
    let timerID: UUID
    let speechID: UUID
    let inputID: UUID?
    let displaySource: PickyDisplaySource
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
    /// Synthetic owner attached when a quick reply carries the "cli" originSource. The
    /// picky CLI does not register a local interactionOwner before submitting (the
    /// submission originates outside the app), so the reducer's ownerFromMetadata maps
    /// the protocol-level origin tag to this case. It intentionally mirrors
    /// .quickInputText for presentation (cursor bubble + TTS).
    case cli
    case system
    case unknown

    var isVoiceOwned: Bool {
        switch self {
        case .voice, .metadataVoice:
            true
        case .text, .quickInputText, .metadataText, .cli, .system, .unknown:
            false
        }
    }

    var isTextOwned: Bool {
        switch self {
        case .text, .quickInputText, .metadataText, .cli:
            true
        case .voice, .metadataVoice, .system, .unknown:
            false
        }
    }

    var usesCursorResponsePresentation: Bool {
        switch self {
        case .quickInputText, .cli:
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
    case pickleCompletion
    case suppressed
}

/// Resolved, display-point annotation geometry rendered on a transparent overlay.
/// It is intentionally separate from both `PickyPointerTarget` and user ink.
struct PickyAgentAnnotation: Equatable, Codable, Identifiable {
    let id: String
    let shape: PickyAnnotationOverlayShape
    let displayFrame: CGRect
    var point: CGPoint?
    var endPoint: CGPoint?
    var rect: CGRect?
    var radius: CGFloat?
    var radiusX: CGFloat?
    var radiusY: CGFloat?
    let spotlightShape: PickyAnnotationSpotlightShape?
    let label: String?
    let expiresAt: Date

    init(
        id: String,
        shape: PickyAnnotationOverlayShape,
        displayFrame: CGRect,
        point: CGPoint? = nil,
        endPoint: CGPoint? = nil,
        rect: CGRect? = nil,
        radius: CGFloat? = nil,
        radiusX: CGFloat? = nil,
        radiusY: CGFloat? = nil,
        spotlightShape: PickyAnnotationSpotlightShape?,
        label: String?,
        expiresAt: Date
    ) {
        self.id = id
        self.shape = shape
        self.displayFrame = displayFrame
        self.point = point
        self.endPoint = endPoint
        self.rect = rect
        self.radius = radius
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.spotlightShape = spotlightShape
        self.label = label
        self.expiresAt = expiresAt
    }
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
    case pickleCompletionPolicy
    case unknown
}

enum PickyOverlayReason: String, Equatable, Codable, Hashable {
    case cursorPreferenceEnabled
    case activeVoiceInput
    case waitingForVoiceResponse
    case speakingResponse
    case activePointerAnimation
    case activeAgentAnnotations
    case activeInkCapture
    case screenContextTarget
    case transientPointerDisplay
    /// Onboarding flow is active. Independent of the user's cursor preference
    /// so the demo can guide a fresh user even if they have the cursor turned
    /// off, then revert to their preferred visibility once the demo finishes.
    case onboardingActive
}

enum PickySpeechStopReason: String, Equatable, Codable {
    case superseded
    case userInterrupted
    case failed
    case unknown
}
