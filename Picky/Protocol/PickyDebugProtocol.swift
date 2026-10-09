//
//  PickyDebugProtocol.swift
//  Picky
//
//  Wire models for the `picky-debug` control channel. The CLI talks to the
//  daemon, the daemon forwards app-owned actions here, and the app publishes a
//  redacted, metadata-only trace of its own input/response transitions.
//
//  Nothing in this file may carry user content. Trace records hold phase labels,
//  correlation identifiers, and lengths — never transcripts, reply text, tool
//  arguments, or file paths.
//

import Foundation

/// App-owned action requested by `picky-debug`. Microphone audio is never
/// injected: `pttPress`/`pttRelease` drive the same push-to-talk lifecycle as
/// the global shortcut, so the real microphone remains the only audio source.
enum PickyDebugAppAction: String, Codable, Equatable, CaseIterable, Sendable {
    case snapshot
    case text
    case pttPress
    case pttRelease
}

/// Daemon-forwarded `debugApp` request.
///
/// `commandId` is the CLI command that started the request and is the
/// correlation root for every trace record the injected input produces. The app
/// binds it to the `inputId` it creates for the production input path, so the
/// resulting transitions are linked by identity rather than by timestamp
/// adjacency.
struct PickyDebugAppRequest: Decodable, Equatable {
    let requestId: String
    let commandId: String
    let action: PickyDebugAppAction
    let text: String?
}

/// Which process observed a transition. The app and the daemon keep independent
/// clocks; the daemon stamps its own receipt time and sequence on arrival, so
/// `monotonicMs` is only comparable within one source.
enum PickyDebugTraceSource: String, Codable, Equatable, Sendable {
    case app
    case daemon
}

enum PickyDebugTraceModality: String, Codable, Equatable, Sendable {
    case audio
    case text
}

/// One redacted semantic transition. Every string field is bounded, and the
/// field set is a closed allowlist: there is deliberately no free-form `details`
/// object that could smuggle user content onto the wire.
struct PickyDebugTraceRecord: Codable, Equatable {
    /// Bound for short labels (`name`, `state`, `previousState`, `outcome`, `event`, `target`).
    /// Counted in UTF-16 units, the unit the daemon's Zod `.max()` uses.
    static let labelCharacterLimit = 96
    /// Bound for correlation identifiers (`inputId`, `contextId`, `sessionId`, `commandId`).
    static let identifierCharacterLimit = 160

    let source: PickyDebugTraceSource
    let name: String
    /// ISO8601 with fractional seconds, from the emitting process's wall clock.
    let timestamp: String
    /// Milliseconds since this process started tracing. Monotonic within one
    /// source only; never compare it against another process's value.
    let monotonicMs: Double
    let inputId: String?
    let contextId: String?
    let sessionId: String?
    let commandId: String?
    let state: String?
    let previousState: String?
    let outcome: String?
    let event: String?
    let target: String?
    let modality: PickyDebugTraceModality?
    let textLength: Int?

    init(
        source: PickyDebugTraceSource,
        name: String,
        timestamp: Date,
        monotonicMs: Double,
        inputId: String? = nil,
        contextId: String? = nil,
        sessionId: String? = nil,
        commandId: String? = nil,
        state: String? = nil,
        previousState: String? = nil,
        outcome: String? = nil,
        event: String? = nil,
        target: String? = nil,
        modality: PickyDebugTraceModality? = nil,
        textLength: Int? = nil
    ) {
        self.source = source
        self.name = Self.label(name) ?? "unknown"
        self.timestamp = PickyDebugTraceClock.iso8601.string(from: timestamp)
        self.monotonicMs = monotonicMs.isFinite ? max(0, monotonicMs) : 0
        self.inputId = Self.identifier(inputId)
        self.contextId = Self.identifier(contextId)
        self.sessionId = Self.identifier(sessionId)
        self.commandId = Self.identifier(commandId)
        self.state = Self.label(state)
        self.previousState = Self.label(previousState)
        self.outcome = Self.label(outcome)
        self.event = Self.label(event)
        self.target = Self.label(target)
        self.modality = modality
        self.textLength = textLength.map { max(0, $0) }
    }

    /// Returns a copy that adopts `commandId`, used when the recorder resolves
    /// an input's correlation root after the record was built. An existing
    /// command id always wins so a late binding cannot rewrite history.
    func adoptingCommandId(_ commandId: String?) -> Self {
        guard self.commandId == nil, let resolved = Self.identifier(commandId) else { return self }
        return Self(
            source: source,
            name: name,
            rawTimestamp: timestamp,
            monotonicMs: monotonicMs,
            inputId: inputId,
            contextId: contextId,
            sessionId: sessionId,
            commandId: resolved,
            state: state,
            previousState: previousState,
            outcome: outcome,
            event: event,
            target: target,
            modality: modality,
            textLength: textLength
        )
    }

    /// Rebuilds a record without re-formatting its timestamp. Values are already
    /// bounded by the designated initializer.
    private init(
        source: PickyDebugTraceSource,
        name: String,
        rawTimestamp: String,
        monotonicMs: Double,
        inputId: String?,
        contextId: String?,
        sessionId: String?,
        commandId: String?,
        state: String?,
        previousState: String?,
        outcome: String?,
        event: String?,
        target: String?,
        modality: PickyDebugTraceModality?,
        textLength: Int?
    ) {
        self.source = source
        self.name = name
        self.timestamp = rawTimestamp
        self.monotonicMs = monotonicMs
        self.inputId = inputId
        self.contextId = contextId
        self.sessionId = sessionId
        self.commandId = commandId
        self.state = state
        self.previousState = previousState
        self.outcome = outcome
        self.event = event
        self.target = target
        self.modality = modality
        self.textLength = textLength
    }

    private static func label(_ value: String?) -> String? {
        bounded(value, limit: labelCharacterLimit)
    }

    private static func identifier(_ value: String?) -> String? {
        bounded(value, limit: identifierCharacterLimit)
    }

    /// Trims to the daemon's bound in UTF-16 units. A grapheme-counted bound
    /// would let one emoji-heavy label fail Zod validation, and the daemon
    /// rejects the whole publish batch when any record is invalid. Truncation
    /// happens on grapheme boundaries so a surrogate pair is never split, and
    /// an over-long first grapheme yields `nil` rather than an empty string,
    /// which the daemon's `.min(1)` would also refuse.
    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf16.count > limit else { return trimmed }
        var truncated = ""
        for character in trimmed {
            guard truncated.utf16.count + character.utf16.count <= limit else { break }
            truncated.append(character)
        }
        return truncated.isEmpty ? nil : truncated
    }
}

enum PickyDebugTraceClock {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Monotonic reference shared by every app-side trace record. `systemUptime`
    /// is CLOCK_MONOTONIC-backed, so it never moves backwards when the wall
    /// clock is adjusted.
    private static let start = ProcessInfo.processInfo.systemUptime

    static func monotonicMs(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        max(0, (now - start) * 1000)
    }
}
