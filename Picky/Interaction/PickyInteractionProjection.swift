import CoreGraphics
import Foundation

struct PickyInteractionProjection: Equatable {
    let state: PickyInteractionState
    let latestDisplayText: String?
    /// Identity of what `latestDisplayText` currently is, computed in the same pass that chose the
    /// text. The cursor bubble keys its no-shrink layout cache on it, so it must change whenever the
    /// bubble shows a different reply or visual segment and stay stable while one reply grows.
    let latestDisplayIdentity: String?
    let overlayVisible: Bool
    let pointerTarget: PickyPointerTarget?
    let agentAnnotations: [PickyAgentAnnotation]
    let showsAgentAnnotationDismissControl: Bool
    let hasActivePointVisualNarration: Bool
    let hasPendingTextSubmission: Bool
    let isWaitingForCursorResponse: Bool
    let isSpeaking: Bool

    init(state: PickyInteractionState) {
        self.state = state
        let display = Self.display(from: state)
        self.latestDisplayText = display.text
        self.latestDisplayIdentity = display.text == nil ? nil : display.identity
        self.overlayVisible = Self.overlayVisible(from: state.overlay)
        self.pointerTarget = state.pointer.target
        self.agentAnnotations = state.annotationScenePhase.presentsAnnotations
            ? state.agentAnnotations
            : []
        self.showsAgentAnnotationDismissControl = state.agentAnnotationsDismissible
            && !self.agentAnnotations.isEmpty
        if state.activeVisualNarrationSentenceCount > 0,
           let identity = state.activeVisualNarrationIdentity,
           let visual = state.visualNarrationSegments[identity.segmentId]?.visual,
           case .point = visual {
            self.hasActivePointVisualNarration = true
        } else {
            self.hasActivePointVisualNarration = false
        }
        self.hasPendingTextSubmission = !state.pendingTextInputs.isEmpty
        self.isWaitingForCursorResponse = Self.isWaitingForCursorResponse(from: state)
        if case .speaking = state.output {
            self.isSpeaking = true
        } else {
            self.isSpeaking = false
        }
    }

    private static func display(
        from state: PickyInteractionState
    ) -> (text: String?, identity: String?) {
        if let identity = state.activeVisualNarrationIdentity,
           let segment = state.visualNarrationSegments[identity.segmentId],
           segment.identity == identity {
            let sentences = segment.sentences
                .sorted { $0.index < $1.index }
                .prefix(state.activeVisualNarrationSentenceCount)
                .map(\.text)
            let text = sentences.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return (text.isEmpty ? nil : text, "segment:\(identity.segmentId)")
        }
        if let streamed = state.streamedResponseText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !streamed.isEmpty {
            // One streamed reply keeps this identity while its sentences accumulate and while its
            // final text replaces them, which is exactly the append-only window the cache stabilizes.
            return (streamed, state.streamedResponseContextID.map { "reply:\($0)" })
        }
        if case .speaking(_, let speechID, _, _, _, _) = state.output,
           state.visualNarrationSpeechMarkers[speechID] != nil {
            return (nil, nil)
        }
        return switch state.output {
        case .idle, .waitingForAgent:
            (
                state.lastDisplayMessage?.text,
                state.lastDisplayMessage.map { "reply:\($0.contextID ?? $0.id)" }
            )
        case .showingTextReply(let contextID, let text, let timerID, _):
            (text, timerID.map { "reply:\(contextID)#\($0)" } ?? "reply:\(contextID)")
        case .speaking(_, let speechID, let text, _, _, _):
            // Not streamed, so each utterance is its own reply: two completions of one session must
            // not share an identity, or the second, shorter one cannot shrink the bubble.
            (text, "speech:\(speechID)")
        case .suppressedReply(let contextID, let text, _, _, _):
            (text, "reply:\(contextID)")
        }
    }

    private static func isWaitingForCursorResponse(from state: PickyInteractionState) -> Bool {
        guard case .waitingForAgent(let inputID, let contextID, _) = state.output else { return false }
        if let inputID, state.pendingTextInputs[inputID]?.source == .quickInput {
            return true
        }
        if let contextID, state.contextOwnership[contextID]?.usesCursorResponsePresentation == true {
            return true
        }
        return false
    }

    private static func overlayVisible(from phase: PickyOverlayPhase) -> Bool {
        switch phase {
        case .hidden:
            false
        case .visible, .hiding:
            true
        }
    }
}
