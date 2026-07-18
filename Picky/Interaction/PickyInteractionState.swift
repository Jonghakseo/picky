import CoreGraphics
import Foundation

struct PickyInteractionState: Equatable, Codable {
    var input: PickyInputPhase
    var output: PickyOutputPhase
    var pointer: PickyPointerPhase
    /// FIFO visits for streamed annotation anchors. The reducer advances this only after
    /// the active buddy flight reports completion, so overlays are never traversed in parallel.
    var pendingAnnotationPointerTargets: [PickyPointerTarget]
    var activeAnnotationPointerID: String?
    var activeAnnotationPointerReturnsToCursor: Bool
    /// True while a streamed annotation turn may still add targets. Its final target parks
    /// rather than returning until a reply, settlement, or clear explicitly ends the turn.
    var annotationPointerTurnActive: Bool
    /// Set by the view after the active target's hover completes and it remains in place.
    var annotationPointerIsParked: Bool
    /// Mirrors the active target's hold policy so the reducer can change it when a turn ends.
    var activeAnnotationPointerParksAtTarget: Bool
    /// Transient AI visual guidance. Kept separate from pointer animations and user ink.
    var agentAnnotations: [PickyAgentAnnotation]
    var overlay: PickyOverlayPhase
    var pendingTextInputs: [UUID: PickyTextInputState]
    var pendingVoiceInputs: [UUID: PickyVoiceInputState]
    var contextOwnership: [String: PickyContextOwner]
    var queuedSpeechReplies: [PickyQueuedSpeechReply]
    /// Context ids whose incremental narration has already entered the TTS queue.
    /// A later final quick reply for the same context updates visible text but must not
    /// enqueue the full reply a second time.
    var streamedNarrationContextIDs: Set<String>
    /// Annotations received from the streamed DSL wait here until narration reaches
    /// their preceding-text position. They are deliberately absent from
    /// `agentAnnotations` so the overlay cannot render them early.
    var pendingAgentAnnotations: [PickyPendingAgentAnnotation]
    /// Cumulative narration characters received for the current main-agent turn.
    var annotationNarrationCharacterCount: Int
    /// The first accepted TTS start for this turn. It anchors visual reveal timing.
    var annotationSpeechAnchor: Date?
    /// A terminal reply/settlement was received; wait for queued speech to drain before
    /// surfacing any still-buffered shapes and sending the buddy back to the cursor.
    var annotationTurnSettled: Bool
    /// Monotonic arrival order used only to gently stagger a silent annotation-only turn.
    var annotationArrivalSequence: Int
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
        pendingAnnotationPointerTargets: [PickyPointerTarget] = [],
        activeAnnotationPointerID: String? = nil,
        activeAnnotationPointerReturnsToCursor: Bool = true,
        annotationPointerTurnActive: Bool = false,
        annotationPointerIsParked: Bool = false,
        activeAnnotationPointerParksAtTarget: Bool = false,
        agentAnnotations: [PickyAgentAnnotation] = [],
        overlay: PickyOverlayPhase = .hidden,
        pendingTextInputs: [UUID: PickyTextInputState] = [:],
        pendingVoiceInputs: [UUID: PickyVoiceInputState] = [:],
        contextOwnership: [String: PickyContextOwner] = [:],
        queuedSpeechReplies: [PickyQueuedSpeechReply] = [],
        streamedNarrationContextIDs: Set<String> = [],
        pendingAgentAnnotations: [PickyPendingAgentAnnotation] = [],
        annotationNarrationCharacterCount: Int = 0,
        annotationSpeechAnchor: Date? = nil,
        annotationTurnSettled: Bool = false,
        annotationArrivalSequence: Int = 0,
        lastDisplayMessage: PickyDisplayMessage? = nil,
        pendingAgentRequestsBySession: [String: PickyPendingAgentRequest] = [:]
    ) {
        self.input = input
        self.output = output
        self.pointer = pointer
        self.pendingAnnotationPointerTargets = pendingAnnotationPointerTargets
        self.activeAnnotationPointerID = activeAnnotationPointerID
        self.activeAnnotationPointerReturnsToCursor = activeAnnotationPointerReturnsToCursor
        self.annotationPointerTurnActive = annotationPointerTurnActive
        self.annotationPointerIsParked = annotationPointerIsParked
        self.activeAnnotationPointerParksAtTarget = activeAnnotationPointerParksAtTarget
        self.agentAnnotations = agentAnnotations
        self.overlay = overlay
        self.pendingTextInputs = pendingTextInputs
        self.pendingVoiceInputs = pendingVoiceInputs
        self.contextOwnership = contextOwnership
        self.queuedSpeechReplies = queuedSpeechReplies
        self.streamedNarrationContextIDs = streamedNarrationContextIDs
        self.pendingAgentAnnotations = pendingAgentAnnotations
        self.annotationNarrationCharacterCount = annotationNarrationCharacterCount
        self.annotationSpeechAnchor = annotationSpeechAnchor
        self.annotationTurnSettled = annotationTurnSettled
        self.annotationArrivalSequence = annotationArrivalSequence
        self.lastDisplayMessage = lastDisplayMessage
        self.pendingAgentRequestsBySession = pendingAgentRequestsBySession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try container.decode(PickyInputPhase.self, forKey: .input)
        self.output = try container.decode(PickyOutputPhase.self, forKey: .output)
        self.pointer = try container.decode(PickyPointerPhase.self, forKey: .pointer)
        self.pendingAnnotationPointerTargets = try container.decodeIfPresent([PickyPointerTarget].self, forKey: .pendingAnnotationPointerTargets) ?? []
        self.activeAnnotationPointerID = try container.decodeIfPresent(String.self, forKey: .activeAnnotationPointerID)
        self.activeAnnotationPointerReturnsToCursor = try container.decodeIfPresent(Bool.self, forKey: .activeAnnotationPointerReturnsToCursor) ?? true
        self.annotationPointerTurnActive = try container.decodeIfPresent(Bool.self, forKey: .annotationPointerTurnActive) ?? false
        self.annotationPointerIsParked = try container.decodeIfPresent(Bool.self, forKey: .annotationPointerIsParked) ?? false
        self.activeAnnotationPointerParksAtTarget = try container.decodeIfPresent(Bool.self, forKey: .activeAnnotationPointerParksAtTarget) ?? false
        self.agentAnnotations = try container.decodeIfPresent([PickyAgentAnnotation].self, forKey: .agentAnnotations) ?? []
        self.overlay = try container.decode(PickyOverlayPhase.self, forKey: .overlay)
        self.pendingTextInputs = try container.decode([UUID: PickyTextInputState].self, forKey: .pendingTextInputs)
        self.pendingVoiceInputs = try container.decode([UUID: PickyVoiceInputState].self, forKey: .pendingVoiceInputs)
        self.contextOwnership = try container.decode([String: PickyContextOwner].self, forKey: .contextOwnership)
        self.queuedSpeechReplies = try container.decode([PickyQueuedSpeechReply].self, forKey: .queuedSpeechReplies)
        self.streamedNarrationContextIDs = try container.decodeIfPresent(Set<String>.self, forKey: .streamedNarrationContextIDs) ?? []
        self.pendingAgentAnnotations = try container.decodeIfPresent([PickyPendingAgentAnnotation].self, forKey: .pendingAgentAnnotations) ?? []
        self.annotationNarrationCharacterCount = try container.decodeIfPresent(Int.self, forKey: .annotationNarrationCharacterCount) ?? 0
        self.annotationSpeechAnchor = try container.decodeIfPresent(Date.self, forKey: .annotationSpeechAnchor)
        self.annotationTurnSettled = try container.decodeIfPresent(Bool.self, forKey: .annotationTurnSettled) ?? false
        self.annotationArrivalSequence = try container.decodeIfPresent(Int.self, forKey: .annotationArrivalSequence) ?? 0
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
    let spotlight: Bool
    let label: String?
    var expiresAt: Date
    /// Non-nil while the overlay is waiting for the first response audio. Once
    /// audio starts, the reducer converts it into `expiresAt` and clears this value.
    var pendingTTL: TimeInterval?

    init(
        id: String,
        shape: PickyAnnotationOverlayShape,
        displayFrame: CGRect,
        point: CGPoint? = nil,
        endPoint: CGPoint? = nil,
        rect: CGRect? = nil,
        spotlight: Bool = false,
        label: String?,
        expiresAt: Date,
        pendingTTL: TimeInterval? = nil
    ) {
        self.id = id
        self.shape = shape
        self.displayFrame = displayFrame
        self.point = point
        self.endPoint = endPoint
        self.rect = rect
        self.spotlight = spotlight
        self.label = label
        self.expiresAt = expiresAt
        self.pendingTTL = pendingTTL
    }

    private enum CodingKeys: String, CodingKey {
        case id, shape, displayFrame, point, endPoint, rect, spotlight, label, expiresAt, pendingTTL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        shape = try container.decode(PickyAnnotationOverlayShape.self, forKey: .shape)
        displayFrame = try container.decode(CGRect.self, forKey: .displayFrame)
        point = try container.decodeIfPresent(CGPoint.self, forKey: .point)
        endPoint = try container.decodeIfPresent(CGPoint.self, forKey: .endPoint)
        rect = try container.decodeIfPresent(CGRect.self, forKey: .rect)
        spotlight = try container.decodeIfPresent(Bool.self, forKey: .spotlight) ?? false
        label = try container.decodeIfPresent(String.self, forKey: .label)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        pendingTTL = try container.decodeIfPresent(TimeInterval.self, forKey: .pendingTTL)
    }
}

/// Buffered annotation metadata. `id` is a timer token rather than the visual
/// annotation id, so a later replacement cannot be revealed by an old timer.
struct PickyPendingAgentAnnotation: Equatable, Codable, Identifiable {
    let id: UUID
    let annotation: PickyAgentAnnotation
    let precedingNarrationCharacters: Int
    let silentTurnSequence: Int
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
    /// False only for an annotation visit that has another queued anchor; that visit
    /// hops directly to the next shape instead of returning to the real cursor.
    let returnsToCursor: Bool
    /// Keeps a final annotation target hovering until its streaming turn settles.
    let parksAtTarget: Bool

    init(
        id: String,
        source: PickyPointerSource = .agent,
        screenLocation: CGPoint,
        displayFrame: CGRect,
        bubbleText: String? = nil,
        duration: TimeInterval,
        targetFrame: CGRect? = nil,
        highlightKind: PickyDetectedHighlightKind = .screenElement,
        returnsToCursor: Bool = true,
        parksAtTarget: Bool = false
    ) {
        self.id = id
        self.source = source
        self.screenLocation = screenLocation
        self.displayFrame = displayFrame
        self.bubbleText = bubbleText
        self.duration = duration
        self.targetFrame = targetFrame
        self.highlightKind = highlightKind
        self.returnsToCursor = returnsToCursor
        self.parksAtTarget = parksAtTarget
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, screenLocation, displayFrame, bubbleText, duration, targetFrame, highlightKind, returnsToCursor, parksAtTarget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(PickyPointerSource.self, forKey: .source)
        screenLocation = try container.decode(CGPoint.self, forKey: .screenLocation)
        displayFrame = try container.decode(CGRect.self, forKey: .displayFrame)
        bubbleText = try container.decodeIfPresent(String.self, forKey: .bubbleText)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        targetFrame = try container.decodeIfPresent(CGRect.self, forKey: .targetFrame)
        highlightKind = try container.decode(PickyDetectedHighlightKind.self, forKey: .highlightKind)
        returnsToCursor = try container.decodeIfPresent(Bool.self, forKey: .returnsToCursor) ?? true
        parksAtTarget = try container.decodeIfPresent(Bool.self, forKey: .parksAtTarget) ?? false
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
