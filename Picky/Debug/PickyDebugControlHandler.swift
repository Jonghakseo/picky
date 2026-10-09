//
//  PickyDebugControlHandler.swift
//  Picky
//
//  Applies a `picky-debug` app action. The handler owns safety checks and the
//  command/input correlation boundary; the actual work runs through the same
//  production entry points a person would use (the composer text path and the
//  push-to-talk lifecycle).
//
//  There is no raw-audio injection here by design: the microphone stays the
//  only audio source, and `pttPress`/`pttRelease` drive the real shortcut path.
//

import Foundation

struct PickyDebugControlError: LocalizedError, Equatable {
    let code: String
    let message: String

    var errorDescription: String? { message }

    static let textRequired = Self(
        code: "debug.text.required",
        message: "Debug text injection needs non-blank text."
    )

    static func textTooLong(limit: Int) -> Self {
        Self(code: "debug.text.tooLong", message: "Debug text must be \(limit) characters or fewer.")
    }

    static func busy(_ reason: String) -> Self {
        Self(code: "debug.busy", message: "Picky cannot take this debug action right now: \(reason).")
    }

    static let pushToTalkAlreadyHeld = Self(
        code: "debug.ptt.alreadyHeld",
        message: "Push-to-talk is already held."
    )

    static let pushToTalkNotHeld = Self(
        code: "debug.ptt.notHeld",
        message: "Push-to-talk is not held."
    )

    static let unavailable = Self(
        code: "debug.unavailable",
        message: "Picky debug control is not ready."
    )
}

@MainActor
final class PickyDebugControlHandler {
    /// Mirrors the daemon's request bound so a long payload fails the same way
    /// on both sides instead of being half-accepted.
    static let textCharacterLimit = 32_000

    struct Dependencies {
        /// Read-only state projection.
        var snapshot: () -> PickyDebugAppSnapshot
        /// Non-nil when the requested action would collide with live input.
        var busyReason: (PickyDebugAppAction) -> String?
        /// Runs the production text submission with the caller-supplied input
        /// id, so the resulting reducer transitions carry that exact id.
        var submitText: (String, UUID) async -> Bool
        var controlPushToTalk: (PickyPushToTalkControlAction) -> Void
        var isPushToTalkHeld: () -> Bool
        /// The voice input the app is recording right now, read straight from
        /// the production push-to-talk state. A press that the app refused
        /// leaves this unchanged, which is how the handler tells a started
        /// recording from a received keystroke.
        var activeVoiceInputID: () -> UUID?
    }

    private let dependencies: Dependencies
    private let recorder: PickyDebugTraceRecorder?

    init(dependencies: Dependencies, recorder: PickyDebugTraceRecorder?) {
        self.dependencies = dependencies
        self.recorder = recorder
    }

    func handle(_ request: PickyDebugAppRequest) async throws -> JSONValue {
        switch request.action {
        case .snapshot:
            return handleSnapshot(request)
        case .text:
            return try await handleText(request)
        case .pttPress, .pttRelease:
            return try handlePushToTalk(request)
        }
    }

    // MARK: - Actions

    private func handleSnapshot(_ request: PickyDebugAppRequest) -> JSONValue {
        recorder?.recordAppEvent(name: "debug.snapshot", commandId: request.commandId, outcome: "read")
        return dependencies.snapshot().jsonValue
    }

    private func handleText(_ request: PickyDebugAppRequest) async throws -> JSONValue {
        let text = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PickyDebugControlError.textRequired }
        // UTF-16 units, matching the daemon's JavaScript `length` bound, so one
        // payload is not accepted on one side and refused on the other.
        let textLength = text.utf16.count
        guard textLength <= Self.textCharacterLimit else {
            throw PickyDebugControlError.textTooLong(limit: Self.textCharacterLimit)
        }
        if let reason = dependencies.busyReason(.text) {
            throw PickyDebugControlError.busy(reason)
        }

        // Bind before dispatching: the reducer events this submission produces
        // must already resolve to this command id when they are traced.
        let inputID = UUID()
        recorder?.bindInjection(commandId: request.commandId, inputID: inputID)
        recorder?.recordAppEvent(
            name: "debug.textInjected",
            commandId: request.commandId,
            inputID: inputID,
            outcome: "dispatched",
            modality: .text,
            textLength: textLength
        )

        let accepted = await dependencies.submitText(text, inputID)
        recorder?.recordAppEvent(
            name: "debug.textSettled",
            commandId: request.commandId,
            inputID: inputID,
            outcome: accepted ? "accepted" : "rejected",
            modality: .text,
            textLength: textLength
        )

        return .object([
            "schemaVersion": .number(Double(PickyDebugAppSnapshot.schemaVersion)),
            "action": .string(request.action.rawValue),
            "accepted": .bool(accepted),
            "inputId": .string(inputID.uuidString),
            "commandId": .string(request.commandId),
            "textLength": .number(Double(textLength)),
            // Acceptance means the app handed the input to the main-agent path.
            // It is not a statement about the model turn finishing, and a CLI
            // timeout or disconnect does not stop an input already running.
            "completesTurn": .bool(false),
        ])
    }

    /// Drives the real push-to-talk lifecycle and reports the production voice
    /// input the edge actually touched. Press correlates to the input the app
    /// created; release correlates to that same input, so the transcript,
    /// context, and reply that follow stay on one timeline.
    private func handlePushToTalk(_ request: PickyDebugAppRequest) throws -> JSONValue {
        let held = dependencies.isPushToTalkHeld()
        let action: PickyPushToTalkControlAction = request.action == .pttPress ? .press : .release
        switch action {
        case .press where held:
            throw PickyDebugControlError.pushToTalkAlreadyHeld
        case .release where !held:
            throw PickyDebugControlError.pushToTalkNotHeld
        default:
            break
        }
        if let reason = dependencies.busyReason(request.action) {
            throw PickyDebugControlError.busy(reason)
        }

        let inputIDBefore = dependencies.activeVoiceInputID()
        dependencies.controlPushToTalk(action)
        let nowHeld = dependencies.isPushToTalkHeld()
        // A press can be swallowed by the production guards (an in-flight
        // dictation, a sending Quick Input draft), which leaves the recorded
        // input untouched. A new id proves input allocation, not that asynchronous microphone startup succeeded.
        let startedInputID = action == .press
            ? dependencies.activeVoiceInputID().flatMap { $0 == inputIDBefore ? nil : $0 }
            : nil
        let correlatedInputID = action == .press ? startedInputID : inputIDBefore
        if let startedInputID {
            recorder?.bindInjection(commandId: request.commandId, inputID: startedInputID)
        }
        let inputStarted = startedInputID != nil
        let outcome = action == .press && !inputStarted ? "pressWithoutInput" : action.rawValue
        recorder?.recordAppEvent(
            name: "debug.pushToTalk",
            commandId: request.commandId,
            inputID: correlatedInputID,
            outcome: outcome,
            modality: .audio
        )

        var fields: [String: JSONValue] = [
            "schemaVersion": .number(Double(PickyDebugAppSnapshot.schemaVersion)),
            "action": .string(request.action.rawValue),
            // The edge the app actually took, not merely that the request
            // arrived. Microphone startup can still fail after this input edge is accepted.
            "applied": .bool(action == .press ? nowHeld : !nowHeld),
            "commandId": .string(request.commandId),
            "pushToTalkHeld": .bool(nowHeld),
            "inputId": correlatedInputID.map { JSONValue.string($0.uuidString) } ?? .null,
            "completesTurn": .bool(false),
        ]
        if action == .press { fields["inputStarted"] = .bool(inputStarted) }
        return .object(fields)
    }
}
