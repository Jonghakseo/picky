import CoreGraphics
import Foundation

struct PickyInteractionProjection: Equatable {
    let state: PickyInteractionState
    let latestDisplayText: String?
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
        self.latestDisplayText = Self.displayText(from: state)
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

    private static func displayText(from state: PickyInteractionState) -> String? {
        if let identity = state.activeVisualNarrationIdentity,
           let segment = state.visualNarrationSegments[identity.segmentId],
           segment.identity == identity {
            let sentences = segment.sentences
                .sorted { $0.index < $1.index }
                .prefix(state.activeVisualNarrationSentenceCount)
                .map(\.text)
            let text = sentences.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let streamed = state.streamedResponseText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !streamed.isEmpty {
            return streamed
        }
        if case .speaking(_, let speechID, _, _, _, _) = state.output,
           state.visualNarrationSpeechMarkers[speechID] != nil {
            return nil
        }
        return switch state.output {
        case .idle, .waitingForAgent:
            state.lastDisplayMessage?.text
        case .showingTextReply(_, let text, _, _):
            text
        case .speaking(_, _, let text, _, _, _):
            text
        case .suppressedReply(_, let text, _, _, _):
            text
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
