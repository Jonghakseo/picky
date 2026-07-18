import Foundation

struct PickyInteractionEnvelope: Equatable, Codable, Identifiable {
    let id: UUID
    let occurredAt: Date
    let event: PickyInteractionEvent
    let correlation: PickyInteractionCorrelation

    init(
        id: UUID,
        occurredAt: Date,
        event: PickyInteractionEvent,
        correlation: PickyInteractionCorrelation = .init(source: .unknown)
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.event = event
        self.correlation = correlation
    }
}

struct PickyInteractionCorrelation: Equatable, Codable {
    var inputID: UUID?
    var contextID: String?
    var speechID: UUID?
    var pointerID: String?
    var sessionID: String?
    var source: PickyInteractionSource

    init(
        inputID: UUID? = nil,
        contextID: String? = nil,
        speechID: UUID? = nil,
        pointerID: String? = nil,
        sessionID: String? = nil,
        source: PickyInteractionSource
    ) {
        self.inputID = inputID
        self.contextID = contextID
        self.speechID = speechID
        self.pointerID = pointerID
        self.sessionID = sessionID
        self.source = source
    }
}

enum PickyInteractionSource: String, Codable, Equatable {
    case voice
    case text
    case quickInput
    case pointer
    case agent
    case system
    case unknown
}

enum PickyQuickReplyOriginSource: String, Codable, Equatable {
    case voice
    case text
    case voiceFollowUp
    case textFollowUp
    case system
    /// Origin tag for replies whose user prompt came in over the picky CLI's external
    /// entry channel. Surfaced as a cursor speech bubble + TTS in the reducer (matches
    /// QuickInput text semantics) so a `picky submit "..."` feels like a panel-side prompt.
    case cli
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = Self.normalized(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func normalized(_ raw: String?) -> Self {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "voice": .voice
        case "text": .text
        case "voicefollowup", "voice-follow-up", "voice_follow_up": .voiceFollowUp
        case "textfollowup", "text-follow-up", "text_follow_up": .textFollowUp
        case "system": .system
        // The decoder runs every string through `normalized` (case-insensitive,
        // trimmed), so the raw enum case match never fires. Without this entry the
        // "cli" originSource the daemon now emits for picky CLI submissions would
        // collapse to `.unknown`, which the reducer's `ownerFromMetadata` turns into
        // a non-cursor owner — no speech bubble, no TTS. Keep this in sync with the
        // PickyContextOwner.cli case and agentd's quickReplyOriginFromContextSource.
        case "cli": .cli
        default: .unknown
        }
    }
}

enum PickyQuickReplyKind: String, Codable, Equatable {
    case main
    case pickleCompletion
    case router
    case handoffAck
    case error
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = Self.normalized(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func normalized(_ raw: String?) -> Self {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "main": .main
        case "picklecompletion", "pickle-completion", "pickle_completion": .pickleCompletion
        case "router": .router
        case "handoffack", "handoff-ack", "handoff_ack": .handoffAck
        case "error": .error
        default: .unknown
        }
    }
}

struct PickyPermissionSnapshot: Equatable, Codable {
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool
    var microphoneGranted: Bool
    var speechRecognitionGranted: Bool

    init(
        accessibilityGranted: Bool = false,
        screenRecordingGranted: Bool = false,
        microphoneGranted: Bool = false,
        speechRecognitionGranted: Bool = false
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.microphoneGranted = microphoneGranted
        self.speechRecognitionGranted = speechRecognitionGranted
    }
}

enum PickyInteractionEvent: Equatable, Codable {
    case appStarted
    case permissionsChanged(PickyPermissionSnapshot)
    case cursorPreferenceChanged(enabled: Bool)

    case voicePressed(targetSessionID: String?)
    case voiceStartFailed(message: String, inputID: UUID)
    case voiceReleased(inputID: UUID)
    case transcriptFinal(text: String, inputID: UUID)
    case transcriptFailed(message: String, inputID: UUID)

    case textSubmitted(text: String, inputID: UUID)
    case textContextCaptured(inputID: UUID, context: PickyContextPacket)
    case textSubmissionAccepted(contextID: String, inputID: UUID)
    case textSubmissionFailed(message: String, inputID: UUID)

    case voiceContextCaptured(inputID: UUID, transcript: String, context: PickyContextPacket, targetSessionID: String?)
    /// External picky CLI submission whose context capture has finished on the host
    /// side and is about to be handed back to picky-agentd. Drives the reducer into
    /// `.waitingForAgent` and registers the .cli cursor owner for the captured
    /// contextID so the cursor loading state is visible until the matching quickReply
    /// arrives. inputID is synthesized at capture time (CLI does not own one).
    case externalContextCaptured(inputID: UUID, text: String, context: PickyContextPacket)
    case agentSubmissionAccepted(contextID: String?, sessionID: String, inputID: UUID?)
    case quickReply(contextID: String, text: String, originSource: PickyQuickReplyOriginSource?, replyKind: PickyQuickReplyKind?, sessionID: String?, inputID: UUID?)
    case narrationChunk(contextID: String, text: String, originSource: PickyQuickReplyOriginSource?, replyKind: PickyQuickReplyKind?, sessionID: String?)
    case streamedQuickReplyFinal(contextID: String, text: String, originSource: PickyQuickReplyOriginSource?, replyKind: PickyQuickReplyKind?, sessionID: String?, inputID: UUID?)
    case passiveAgentSummary(sessionID: String, text: String)
    case pickleCompleted(sessionID: String, summary: String?)
    /// Main agent finished without a quick reply (for example, a DSL-only overlay turn).
    case mainTurnSettled(contextID: String)
    /// Synthetic terminal signal dispatched by `CompanionManager` when an agentd session
    /// transitions to a terminal status (`cancelled`/`failed`) without emitting its own
    /// `quickReply` — typically a HUD abort or a runtime crash. The reducer uses this to
    /// release the cursor's `.waitingForAgent` output that would otherwise stay yellow
    /// forever. Idempotent: replaying for an unknown session is a no-op (`staleEvent`).
    case sessionTerminated(sessionID: String)

    case pointerRequested(PickyPointerTarget)
    case pointerCancelled(pointerID: String, reason: PickyPointerCancelReason)
    case pointerAnimationFinished(pointerID: String)
    case agentAnnotationsRequested(mode: PickyAnnotationOverlayMode, annotations: [PickyAgentAnnotation])
    /// Starts deferred annotation expiry when final-reply fallback has no incremental audio.
    case agentAnnotationsStartTTL(now: Date)
    case agentAnnotationsExpired(now: Date)
    case agentAnnotationsClearedForUserInput

    case speechStarted(text: String, speechID: UUID, sourceContextID: String?)
    case speechFinished(speechID: UUID)
    case speechFailed(speechID: UUID)
    case minimumDisplayTimerFired(timerID: UUID, speechID: UUID?, inputID: UUID?)

    case overlayShown(reason: PickyOverlayReason)
    case overlayHidden(reason: PickyOverlayReason)
    case transientHideTimerFired(timerID: UUID)

    private enum CaseKey: String, CodingKey {
        case appStarted, permissionsChanged, cursorPreferenceChanged
        case voicePressed, voiceStartFailed, voiceReleased, transcriptFinal, transcriptFailed
        case textSubmitted, textContextCaptured, textSubmissionAccepted, textSubmissionFailed
        case voiceContextCaptured, externalContextCaptured, agentSubmissionAccepted, quickReply, narrationChunk, streamedQuickReplyFinal, passiveAgentSummary, pickleCompleted, mainTurnSettled, sessionTerminated
        case pointerRequested, pointerCancelled, pointerAnimationFinished
        case agentAnnotationsRequested, agentAnnotationsStartTTL, agentAnnotationsExpired, agentAnnotationsClearedForUserInput
        case speechStarted, speechFinished, speechFailed, minimumDisplayTimerFired
        case overlayShown, overlayHidden, transientHideTimerFired
    }

    fileprivate enum FieldKey: String, CodingKey {
        case enabled, targetSessionID, message, inputID, text, context, contextID, contextId, transcript, sessionID, sessionId
        case originSource, replyKind, source, summary, pointerID, pointerId, reason, speechID, speechId, sourceContextID
        case timerID, timerId, mode, annotations, now
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing interaction event case"))
        }
        switch key {
        case .appStarted:
            self = .appStarted
        case .permissionsChanged:
            self = .permissionsChanged(try container.decode(PickyPermissionSnapshot.self, forKey: key))
        case .cursorPreferenceChanged:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .cursorPreferenceChanged(enabled: try payload.decode(Bool.self, forKey: .enabled))
        case .voicePressed:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .voicePressed(targetSessionID: try payload.decodeIfPresent(String.self, forKey: .targetSessionID))
        case .voiceStartFailed:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .voiceStartFailed(message: try payload.decode(String.self, forKey: .message), inputID: try payload.decode(UUID.self, forKey: .inputID))
        case .voiceReleased:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .voiceReleased(inputID: try payload.decode(UUID.self, forKey: .inputID))
        case .transcriptFinal:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .transcriptFinal(text: try payload.decode(String.self, forKey: .text), inputID: try payload.decode(UUID.self, forKey: .inputID))
        case .transcriptFailed:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .transcriptFailed(message: try payload.decode(String.self, forKey: .message), inputID: try payload.decode(UUID.self, forKey: .inputID))
        case .textSubmitted:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .textSubmitted(text: try payload.decode(String.self, forKey: .text), inputID: try payload.decode(UUID.self, forKey: .inputID))
        case .textContextCaptured:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .textContextCaptured(inputID: try payload.decode(UUID.self, forKey: .inputID), context: try payload.decode(PickyContextPacket.self, forKey: .context))
        case .textSubmissionAccepted:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .textSubmissionAccepted(contextID: try payload.decodeFlexibleString(primary: .contextID, fallback: .contextId), inputID: try payload.decode(UUID.self, forKey: .inputID))
        case .textSubmissionFailed:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .textSubmissionFailed(message: try payload.decode(String.self, forKey: .message), inputID: try payload.decode(UUID.self, forKey: .inputID))
        case .voiceContextCaptured:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .voiceContextCaptured(
                inputID: try payload.decode(UUID.self, forKey: .inputID),
                transcript: try payload.decode(String.self, forKey: .transcript),
                context: try payload.decode(PickyContextPacket.self, forKey: .context),
                targetSessionID: try payload.decodeIfPresent(String.self, forKey: .targetSessionID)
            )
        case .externalContextCaptured:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .externalContextCaptured(
                inputID: try payload.decode(UUID.self, forKey: .inputID),
                text: try payload.decode(String.self, forKey: .text),
                context: try payload.decode(PickyContextPacket.self, forKey: .context)
            )
        case .agentSubmissionAccepted:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .agentSubmissionAccepted(
                contextID: try payload.decodeFlexibleOptionalString(primary: .contextID, fallback: .contextId),
                sessionID: try payload.decodeFlexibleString(primary: .sessionID, fallback: .sessionId),
                inputID: try payload.decodeIfPresent(UUID.self, forKey: .inputID)
            )
        case .quickReply:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            let legacySource = try payload.decodeIfPresent(String.self, forKey: .source)
            let explicitOrigin = try payload.decodeIfPresent(PickyQuickReplyOriginSource.self, forKey: .originSource)
            let explicitKind = try payload.decodeIfPresent(PickyQuickReplyKind.self, forKey: .replyKind)
            self = .quickReply(
                contextID: try payload.decodeFlexibleString(primary: .contextID, fallback: .contextId),
                text: try payload.decode(String.self, forKey: .text),
                originSource: explicitOrigin ?? Self.legacyOrigin(from: legacySource) ?? .unknown,
                replyKind: explicitKind ?? Self.legacyKind(from: legacySource) ?? .unknown,
                sessionID: try payload.decodeFlexibleOptionalString(primary: .sessionID, fallback: .sessionId),
                inputID: try payload.decodeIfPresent(UUID.self, forKey: .inputID)
            )
        case .narrationChunk:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .narrationChunk(
                contextID: try payload.decodeFlexibleString(primary: .contextID, fallback: .contextId),
                text: try payload.decode(String.self, forKey: .text),
                originSource: try payload.decodeIfPresent(PickyQuickReplyOriginSource.self, forKey: .originSource),
                replyKind: try payload.decodeIfPresent(PickyQuickReplyKind.self, forKey: .replyKind),
                sessionID: try payload.decodeIfPresent(String.self, forKey: .sessionID)
            )
        case .streamedQuickReplyFinal:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .streamedQuickReplyFinal(
                contextID: try payload.decodeFlexibleString(primary: .contextID, fallback: .contextId),
                text: try payload.decode(String.self, forKey: .text),
                originSource: try payload.decodeIfPresent(PickyQuickReplyOriginSource.self, forKey: .originSource),
                replyKind: try payload.decodeIfPresent(PickyQuickReplyKind.self, forKey: .replyKind),
                sessionID: try payload.decodeIfPresent(String.self, forKey: .sessionID),
                inputID: try payload.decodeIfPresent(UUID.self, forKey: .inputID)
            )
        case .passiveAgentSummary:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .passiveAgentSummary(sessionID: try payload.decodeFlexibleString(primary: .sessionID, fallback: .sessionId), text: try payload.decode(String.self, forKey: .text))
        case .pickleCompleted:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .pickleCompleted(sessionID: try payload.decodeFlexibleString(primary: .sessionID, fallback: .sessionId), summary: try payload.decodeIfPresent(String.self, forKey: .summary))
        case .mainTurnSettled:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .mainTurnSettled(contextID: try payload.decodeFlexibleString(primary: .contextID, fallback: .contextId))
        case .sessionTerminated:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .sessionTerminated(sessionID: try payload.decodeFlexibleString(primary: .sessionID, fallback: .sessionId))
        case .pointerRequested:
            self = .pointerRequested(try container.decode(PickyPointerTarget.self, forKey: key))
        case .pointerCancelled:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .pointerCancelled(pointerID: try payload.decodeFlexibleString(primary: .pointerID, fallback: .pointerId), reason: try payload.decode(PickyPointerCancelReason.self, forKey: .reason))
        case .pointerAnimationFinished:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .pointerAnimationFinished(pointerID: try payload.decodeFlexibleString(primary: .pointerID, fallback: .pointerId))
        case .agentAnnotationsRequested:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .agentAnnotationsRequested(
                mode: try payload.decode(PickyAnnotationOverlayMode.self, forKey: .mode),
                annotations: try payload.decode([PickyAgentAnnotation].self, forKey: .annotations)
            )
        case .agentAnnotationsStartTTL:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .agentAnnotationsStartTTL(now: try payload.decode(Date.self, forKey: .now))
        case .agentAnnotationsExpired:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .agentAnnotationsExpired(now: try payload.decode(Date.self, forKey: .now))
        case .agentAnnotationsClearedForUserInput:
            self = .agentAnnotationsClearedForUserInput
        case .speechStarted:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .speechStarted(text: try payload.decode(String.self, forKey: .text), speechID: try payload.decodeFlexibleUUID(primary: .speechID, fallback: .speechId), sourceContextID: try payload.decodeIfPresent(String.self, forKey: .sourceContextID))
        case .speechFinished:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .speechFinished(speechID: try payload.decodeFlexibleUUID(primary: .speechID, fallback: .speechId))
        case .speechFailed:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .speechFailed(speechID: try payload.decodeFlexibleUUID(primary: .speechID, fallback: .speechId))
        case .minimumDisplayTimerFired:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .minimumDisplayTimerFired(
                timerID: try payload.decodeFlexibleUUID(primary: .timerID, fallback: .timerId),
                speechID: try payload.decodeFlexibleOptionalUUID(primary: .speechID, fallback: .speechId),
                inputID: try payload.decodeIfPresent(UUID.self, forKey: .inputID)
            )
        case .overlayShown:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .overlayShown(reason: try payload.decode(PickyOverlayReason.self, forKey: .reason))
        case .overlayHidden:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .overlayHidden(reason: try payload.decode(PickyOverlayReason.self, forKey: .reason))
        case .transientHideTimerFired:
            let payload = try container.nestedContainer(keyedBy: FieldKey.self, forKey: key)
            self = .transientHideTimerFired(timerID: try payload.decodeFlexibleUUID(primary: .timerID, fallback: .timerId))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .appStarted:
            try container.encode([String: String](), forKey: .appStarted)
        case .permissionsChanged(let snapshot):
            try container.encode(snapshot, forKey: .permissionsChanged)
        case .cursorPreferenceChanged(let enabled):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .cursorPreferenceChanged)
            try payload.encode(enabled, forKey: .enabled)
        case .voicePressed(let targetSessionID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .voicePressed)
            try payload.encodeIfPresent(targetSessionID, forKey: .targetSessionID)
        case .voiceStartFailed(let message, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .voiceStartFailed)
            try payload.encode(message, forKey: .message); try payload.encode(inputID, forKey: .inputID)
        case .voiceReleased(let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .voiceReleased)
            try payload.encode(inputID, forKey: .inputID)
        case .transcriptFinal(let text, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .transcriptFinal)
            try payload.encode(text, forKey: .text); try payload.encode(inputID, forKey: .inputID)
        case .transcriptFailed(let message, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .transcriptFailed)
            try payload.encode(message, forKey: .message); try payload.encode(inputID, forKey: .inputID)
        case .textSubmitted(let text, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .textSubmitted)
            try payload.encode(text, forKey: .text); try payload.encode(inputID, forKey: .inputID)
        case .textContextCaptured(let inputID, let context):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .textContextCaptured)
            try payload.encode(inputID, forKey: .inputID); try payload.encode(context, forKey: .context)
        case .textSubmissionAccepted(let contextID, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .textSubmissionAccepted)
            try payload.encode(contextID, forKey: .contextID); try payload.encode(inputID, forKey: .inputID)
        case .textSubmissionFailed(let message, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .textSubmissionFailed)
            try payload.encode(message, forKey: .message); try payload.encode(inputID, forKey: .inputID)
        case .voiceContextCaptured(let inputID, let transcript, let context, let targetSessionID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .voiceContextCaptured)
            try payload.encode(inputID, forKey: .inputID); try payload.encode(transcript, forKey: .transcript); try payload.encode(context, forKey: .context); try payload.encodeIfPresent(targetSessionID, forKey: .targetSessionID)
        case .externalContextCaptured(let inputID, let text, let context):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .externalContextCaptured)
            try payload.encode(inputID, forKey: .inputID); try payload.encode(text, forKey: .text); try payload.encode(context, forKey: .context)
        case .agentSubmissionAccepted(let contextID, let sessionID, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .agentSubmissionAccepted)
            try payload.encodeIfPresent(contextID, forKey: .contextID); try payload.encode(sessionID, forKey: .sessionID); try payload.encodeIfPresent(inputID, forKey: .inputID)
        case .quickReply(let contextID, let text, let originSource, let replyKind, let sessionID, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .quickReply)
            try payload.encode(contextID, forKey: .contextID); try payload.encode(text, forKey: .text); try payload.encodeIfPresent(originSource, forKey: .originSource); try payload.encodeIfPresent(replyKind, forKey: .replyKind); try payload.encodeIfPresent(sessionID, forKey: .sessionID); try payload.encodeIfPresent(inputID, forKey: .inputID)
        case .narrationChunk(let contextID, let text, let originSource, let replyKind, let sessionID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .narrationChunk)
            try payload.encode(contextID, forKey: .contextID); try payload.encode(text, forKey: .text); try payload.encodeIfPresent(originSource, forKey: .originSource); try payload.encodeIfPresent(replyKind, forKey: .replyKind); try payload.encodeIfPresent(sessionID, forKey: .sessionID)
        case .streamedQuickReplyFinal(let contextID, let text, let originSource, let replyKind, let sessionID, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .streamedQuickReplyFinal)
            try payload.encode(contextID, forKey: .contextID); try payload.encode(text, forKey: .text); try payload.encodeIfPresent(originSource, forKey: .originSource); try payload.encodeIfPresent(replyKind, forKey: .replyKind); try payload.encodeIfPresent(sessionID, forKey: .sessionID); try payload.encodeIfPresent(inputID, forKey: .inputID)
        case .passiveAgentSummary(let sessionID, let text):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .passiveAgentSummary)
            try payload.encode(sessionID, forKey: .sessionID); try payload.encode(text, forKey: .text)
        case .pickleCompleted(let sessionID, let summary):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .pickleCompleted)
            try payload.encode(sessionID, forKey: .sessionID); try payload.encodeIfPresent(summary, forKey: .summary)
        case .mainTurnSettled(let contextID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .mainTurnSettled)
            try payload.encode(contextID, forKey: .contextID)
        case .sessionTerminated(let sessionID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .sessionTerminated)
            try payload.encode(sessionID, forKey: .sessionID)
        case .pointerRequested(let target):
            try container.encode(target, forKey: .pointerRequested)
        case .pointerCancelled(let pointerID, let reason):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .pointerCancelled)
            try payload.encode(pointerID, forKey: .pointerID); try payload.encode(reason, forKey: .reason)
        case .pointerAnimationFinished(let pointerID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .pointerAnimationFinished)
            try payload.encode(pointerID, forKey: .pointerID)
        case .agentAnnotationsRequested(let mode, let annotations):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .agentAnnotationsRequested)
            try payload.encode(mode, forKey: .mode); try payload.encode(annotations, forKey: .annotations)
        case .agentAnnotationsStartTTL(let now):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .agentAnnotationsStartTTL)
            try payload.encode(now, forKey: .now)
        case .agentAnnotationsExpired(let now):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .agentAnnotationsExpired)
            try payload.encode(now, forKey: .now)
        case .agentAnnotationsClearedForUserInput:
            try container.encode([String: String](), forKey: .agentAnnotationsClearedForUserInput)
        case .speechStarted(let text, let speechID, let sourceContextID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .speechStarted)
            try payload.encode(text, forKey: .text); try payload.encode(speechID, forKey: .speechID); try payload.encodeIfPresent(sourceContextID, forKey: .sourceContextID)
        case .speechFinished(let speechID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .speechFinished)
            try payload.encode(speechID, forKey: .speechID)
        case .speechFailed(let speechID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .speechFailed)
            try payload.encode(speechID, forKey: .speechID)
        case .minimumDisplayTimerFired(let timerID, let speechID, let inputID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .minimumDisplayTimerFired)
            try payload.encode(timerID, forKey: .timerID); try payload.encodeIfPresent(speechID, forKey: .speechID); try payload.encodeIfPresent(inputID, forKey: .inputID)
        case .overlayShown(let reason):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .overlayShown)
            try payload.encode(reason, forKey: .reason)
        case .overlayHidden(let reason):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .overlayHidden)
            try payload.encode(reason, forKey: .reason)
        case .transientHideTimerFired(let timerID):
            var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .transientHideTimerFired)
            try payload.encode(timerID, forKey: .timerID)
        }
    }

    private static func legacyOrigin(from source: String?) -> PickyQuickReplyOriginSource? {
        let value = PickyQuickReplyOriginSource.normalized(source)
        return value == .unknown && source == nil ? nil : value
    }

    private static func legacyKind(from source: String?) -> PickyQuickReplyKind? {
        let value = PickyQuickReplyKind.normalized(source)
        return value == .unknown && source == nil ? nil : value
    }
}

private extension KeyedDecodingContainer where K == PickyInteractionEvent.FieldKey {
    func decodeFlexibleString(primary: K, fallback: K) throws -> String {
        if let value = try decodeIfPresent(String.self, forKey: primary) { return value }
        return try decode(String.self, forKey: fallback)
    }

    func decodeFlexibleOptionalString(primary: K, fallback: K) throws -> String? {
        if let value = try decodeIfPresent(String.self, forKey: primary) { return value }
        return try decodeIfPresent(String.self, forKey: fallback)
    }

    func decodeFlexibleUUID(primary: K, fallback: K) throws -> UUID {
        if let value = try decodeIfPresent(UUID.self, forKey: primary) { return value }
        return try decode(UUID.self, forKey: fallback)
    }

    func decodeFlexibleOptionalUUID(primary: K, fallback: K) throws -> UUID? {
        if let value = try decodeIfPresent(UUID.self, forKey: primary) { return value }
        return try decodeIfPresent(UUID.self, forKey: fallback)
    }
}
