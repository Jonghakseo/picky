//
//  PickyDebugControlTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyDebugTraceRedactionTests {
    private func sample(
        event: PickyInteractionEvent,
        correlation: PickyInteractionCorrelation,
        state: PickyInteractionState = PickyInteractionState()
    ) -> PickyInteractionTraceSample {
        PickyInteractionTraceSample(
            event: event,
            correlation: correlation,
            previousState: PickyInteractionState(),
            state: state,
            sequence: 1,
            dropped: false
        )
    }

    private func encoded(_ record: PickyDebugTraceRecord) throws -> String {
        String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    }

    @Test func traceCarriesTextLengthButNeverTheTypedText() throws {
        let inputID = UUID()
        let record = PickyInteractionTraceMapper.record(sample(
            event: .textSubmitted(text: "wire me the password", inputID: inputID),
            correlation: PickyInteractionCorrelation(inputID: inputID, source: .quickInput),
            state: PickyInteractionState(input: .textSubmitting(inputID: inputID, text: "wire me the password"))
        ))

        #expect(record.textLength == 20)
        #expect(record.inputId == inputID.uuidString)
        #expect(record.modality == .text)
        #expect(record.state?.contains("textSubmitting") == true)
        #expect(record.event == "quickInput")
        let json = try encoded(record)
        #expect(!json.contains("password"))
    }

    @Test func traceKeepsTranscriptsAndRepliesOffTheWire() throws {
        let inputID = UUID()
        let speechID = UUID()
        let records = [
            PickyInteractionTraceMapper.record(sample(
                event: .transcriptFinal(text: "my home address is 12 Elm", inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
            )),
            PickyInteractionTraceMapper.record(sample(
                event: .quickReply(
                    contextID: "ctx-1",
                    text: "here is the secret",
                    originSource: .voice,
                    replyKind: .main,
                    sessionID: "session-1",
                    inputID: inputID
                ),
                correlation: PickyInteractionCorrelation(inputID: inputID, contextID: "ctx-1", source: .agent)
            )),
            PickyInteractionTraceMapper.record(sample(
                event: .speechStarted(text: "spoken secret", speechID: speechID, sourceContextID: "ctx-1"),
                correlation: PickyInteractionCorrelation(contextID: "ctx-1", source: .agent)
            )),
        ]

        for record in records {
            let json = try encoded(record)
            #expect(!json.contains("secret"))
            #expect(!json.contains("Elm"))
        }
        #expect(records[1].contextId == "ctx-1")
        #expect(records[1].sessionId == "session-1")
        #expect(records[1].outcome == "main")
    }

    @Test func staleProjectionsAreReportedWithoutClaimingAStateChange() {
        let inputID = UUID()
        let previous = PickyInteractionState(input: .textSubmitting(inputID: inputID, text: "hi"))
        let record = PickyInteractionTraceMapper.record(PickyInteractionTraceSample(
            event: .textSubmissionFailed(message: "boom", inputID: inputID),
            correlation: PickyInteractionCorrelation(inputID: inputID, source: .text),
            previousState: previous,
            state: previous,
            sequence: 3,
            dropped: true
        ))

        #expect(record.outcome == "staleDropped")
        #expect(record.state == record.previousState)
    }

    @Test func labelsAndIdentifiersStayWithinTheirWireBounds() {
        let record = PickyDebugTraceRecord(
            source: .app,
            name: String(repeating: "n", count: 400),
            timestamp: Date(),
            monotonicMs: -1,
            inputId: String(repeating: "i", count: 400),
            outcome: String(repeating: "o", count: 400),
            textLength: -5
        )

        #expect(record.name.count == PickyDebugTraceRecord.labelCharacterLimit)
        #expect(record.inputId?.count == PickyDebugTraceRecord.identifierCharacterLimit)
        #expect(record.outcome?.count == PickyDebugTraceRecord.labelCharacterLimit)
        #expect(record.monotonicMs == 0)
        #expect(record.textLength == 0)
    }

    @Test func boundsAreMeasuredInTheSameUnitsTheDaemonValidates() {
        // Zod counts UTF-16 units, and one invalid record makes the daemon
        // reject the entire publish batch, so a grapheme-counted bound would
        // lose unrelated records with it.
        let record = PickyDebugTraceRecord(
            source: .app,
            name: String(repeating: "\u{1F9EA}", count: 200),
            timestamp: Date(),
            monotonicMs: 1,
            outcome: String(repeating: "\u{AC00}", count: 200)
        )

        #expect(record.name.utf16.count <= PickyDebugTraceRecord.labelCharacterLimit)
        #expect((record.outcome?.utf16.count ?? 0) <= PickyDebugTraceRecord.labelCharacterLimit)
        // Truncation lands on grapheme boundaries, so the label stays readable.
        #expect(record.name.allSatisfy { $0 == "\u{1F9EA}" })
        #expect(record.outcome?.isEmpty == false)
    }

    @Test func blankIdentifiersAreOmittedRatherThanSentEmpty() {
        let record = PickyDebugTraceRecord(
            source: .app,
            name: "debug.snapshot",
            timestamp: Date(),
            monotonicMs: 12,
            inputId: "   ",
            contextId: ""
        )

        #expect(record.inputId == nil)
        #expect(record.contextId == nil)
    }
}

@MainActor
struct PickyDebugTraceRecorderTests {
    private func record(
        name: String,
        inputId: String? = nil,
        contextId: String? = nil,
        commandId: String? = nil
    ) -> PickyDebugTraceRecord {
        PickyDebugTraceRecord(
            source: .app,
            name: name,
            timestamp: Date(timeIntervalSince1970: 0),
            monotonicMs: 0,
            inputId: inputId,
            contextId: contextId,
            commandId: commandId
        )
    }

    @Test func injectedCommandFollowsTheInputThroughItsCapturedContext() async {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }
        let inputID = UUID()

        recorder.bindInjection(commandId: "cmd-debug-1", inputID: inputID)
        // The reducer first reports the input alone, then the context it captured.
        recorder.record(record(name: "interaction.textSubmitted", inputId: inputID.uuidString))
        recorder.record(record(
            name: "interaction.textContextCaptured",
            inputId: inputID.uuidString,
            contextId: "ctx-42"
        ))
        // A later reply knows only the context id.
        recorder.record(record(name: "interaction.quickReply", contextId: "ctx-42"))
        await recorder.flush()

        #expect(published.count == 3)
        #expect(published.allSatisfy { $0.commandId == "cmd-debug-1" })
    }

    @Test func unrelatedInputsAreNotAdoptedByTheInjectedCommand() async {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }

        recorder.bindInjection(commandId: "cmd-debug-1", inputID: UUID())
        recorder.record(record(name: "interaction.textSubmitted", inputId: UUID().uuidString))
        recorder.record(record(name: "interaction.quickReply", contextId: "ctx-other"))
        await recorder.flush()

        #expect(published.count == 2)
        #expect(published.allSatisfy { $0.commandId == nil })
    }

    @Test func anExplicitCommandIdIsNeverRewrittenByCorrelation() async {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }
        let inputID = UUID()

        recorder.bindInjection(commandId: "cmd-debug-1", inputID: inputID)
        recorder.record(record(name: "debug.textInjected", inputId: inputID.uuidString, commandId: "cmd-debug-2"))
        await recorder.flush()

        #expect(published.first?.commandId == "cmd-debug-2")
    }

    @Test func publishesInBatchesWithinTheProtocolLimit() async {
        var batches: [[PickyDebugTraceRecord]] = []
        let recorder = PickyDebugTraceRecorder { batches.append($0); return true }

        for index in 0..<250 {
            recorder.record(record(name: "interaction.narrationChunk", contextId: "ctx-\(index)"))
        }
        await recorder.flush()

        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.count <= 100 })
        #expect(batches.reduce(0) { $0 + $1.count } == 250)
    }

    @Test func bufferOverflowDropsOldestRecordsAndSaysSo() async {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder(
            configuration: PickyDebugTraceRecorder.Configuration(pendingCapacity: 3, batchLimit: 100)
        ) { published.append(contentsOf: $0); return true }

        for index in 0..<6 {
            recorder.record(record(name: "interaction.narrationChunk", contextId: "ctx-\(index)"))
        }
        await recorder.flush()

        #expect(recorder.droppedCount > 0)
        #expect(recorder.recordedCount == 6)
        #expect(published.contains { $0.name == "debug.traceDropped" })
        // The newest records survive; the oldest are the ones that went.
        #expect(published.contains { $0.contextId == "ctx-5" })
        #expect(!published.contains { $0.contextId == "ctx-0" })
    }

    /// Publisher a test can park inside, so a stalled socket is observable
    /// instead of simulated by counting calls.
    private final class GatedPublisher {
        var gated = false
        var outcome = true
        private(set) var attempts = 0
        private(set) var maxInFlight = 0
        private(set) var published: [PickyDebugTraceRecord] = []
        private var inFlight = 0
        private var parked: CheckedContinuation<Void, Never>?

        func publish(_ records: [PickyDebugTraceRecord]) async -> Bool {
            attempts += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            if gated { await withCheckedContinuation { parked = $0 } }
            inFlight -= 1
            // A refused publish never reaches the daemon, so it must not show
            // up here either.
            if outcome { published.append(contentsOf: records) }
            return outcome
        }

        func release() {
            parked?.resume()
            parked = nil
        }
    }

    private func settle(until predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<50 {
            if predicate() { return }
            await Task.yield()
        }
    }

    @Test func aStalledTransportHoldsOneBatchAndBoundsThePendingQueue() async {
        let publisher = GatedPublisher()
        publisher.gated = true
        let recorder = PickyDebugTraceRecorder(
            configuration: PickyDebugTraceRecorder.Configuration(pendingCapacity: 5, batchLimit: 2)
        ) { await publisher.publish($0) }

        for index in 0..<20 {
            recorder.record(record(name: "interaction.narrationChunk", contextId: "ctx-\(index)"))
        }
        await settle { publisher.attempts >= 1 }

        // One drain task, one batch on the wire, and a queue that cannot grow
        // past its capacity no matter how long the socket stays parked.
        #expect(publisher.attempts == 1)
        #expect(publisher.maxInFlight == 1)
        #expect(recorder.hasInFlightPublish)
        #expect(recorder.pendingCount <= 5)
        #expect(recorder.droppedCount > 0)

        publisher.gated = false
        publisher.release()
        await recorder.flush()

        #expect(publisher.maxInFlight == 1)
        #expect(publisher.published.contains { $0.name == "debug.traceDropped" })
        #expect(recorder.pendingCount == 0)
    }

    @Test func aRefusedPublishIsCountedAndReportedWhenTheSocketRecovers() async {
        let publisher = GatedPublisher()
        publisher.outcome = false
        var now = 0.0
        let recorder = PickyDebugTraceRecorder(
            configuration: PickyDebugTraceRecorder.Configuration(failureBackoffMs: 1_000),
            monotonic: { now }
        ) { await publisher.publish($0) }

        recorder.record(record(name: "interaction.textSubmitted", inputId: UUID().uuidString))
        await recorder.flush()

        // A refused publish is a real gap: the daemon never assigned those
        // records a sequence, so nothing downstream can infer the loss.
        #expect(recorder.transportFailureCount == 1)
        #expect(recorder.droppedCount == 1)
        #expect(publisher.published.isEmpty)

        for index in 0..<50 {
            recorder.record(record(name: "interaction.narrationChunk", contextId: "ctx-\(index)"))
        }
        await settle { publisher.attempts > 1 }

        // Backoff: a dead socket is not retried once per recorded transition,
        // and the records keep queueing instead of being thrown away.
        #expect(publisher.attempts == 1)
        #expect(recorder.pendingCount == 50)

        publisher.outcome = true
        now = 2_000
        await recorder.flush()

        #expect(publisher.published.contains { $0.name == "debug.traceDropped" && $0.outcome == "dropped=1" })
        #expect(publisher.published.filter { $0.name == "interaction.narrationChunk" }.count == 50)
        #expect(recorder.droppedCount == 1)
    }
}

@MainActor
struct PickyDebugControlHandlerTests {
    private final class Spy {
        var submitted: [(String, UUID)] = []
        var pushToTalk: [PickyPushToTalkControlAction] = []
        var held = false
        var busyReason: String?
        var accept = true
        /// Mirrors `CompanionManager.interactionVoiceInputID`: the production
        /// press mints it synchronously, and a press the app refuses leaves it
        /// untouched.
        var activeVoiceInputID: UUID?
        var startsRecording = true
    }

    private func makeHandler(
        spy: Spy,
        recorder: PickyDebugTraceRecorder? = nil
    ) -> PickyDebugControlHandler {
        PickyDebugControlHandler(
            dependencies: PickyDebugControlHandler.Dependencies(
                snapshot: { PickyDebugAppSnapshot.unavailable },
                busyReason: { _ in spy.busyReason },
                submitText: { text, inputID in
                    spy.submitted.append((text, inputID))
                    return spy.accept
                },
                controlPushToTalk: { action in
                    spy.pushToTalk.append(action)
                    spy.held = action == .press
                    if action == .press, spy.startsRecording { spy.activeVoiceInputID = UUID() }
                },
                isPushToTalkHeld: { spy.held },
                activeVoiceInputID: { spy.activeVoiceInputID }
            ),
            recorder: recorder
        )
    }

    private func request(_ action: PickyDebugAppAction, text: String? = nil) -> PickyDebugAppRequest {
        PickyDebugAppRequest(requestId: "req-1", commandId: "cmd-1", action: action, text: text)
    }

    private func field(_ value: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let fields) = value else { return nil }
        return fields[key]
    }

    @Test func textInjectionRunsTheProductionPathWithTheCorrelatedInputID() async throws {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }
        let spy = Spy()
        let handler = makeHandler(spy: spy, recorder: recorder)

        let result = try await handler.handle(request(.text, text: "  run the build  "))
        await recorder.flush()

        #expect(spy.submitted.count == 1)
        #expect(spy.submitted.first?.0 == "run the build")
        #expect(field(result, "accepted") == .bool(true))
        #expect(field(result, "completesTurn") == .bool(false))
        let reportedInputID = try #require(field(result, "inputId"))
        #expect(reportedInputID == .string(try #require(spy.submitted.first?.1.uuidString)))
        // The injected command must be resolvable from the reducer's input id.
        #expect(published.allSatisfy { $0.commandId == "cmd-1" })
        #expect(published.contains { $0.name == "debug.textSettled" && $0.outcome == "accepted" })
        #expect(!published.contains { ($0.outcome ?? "").contains("build") })
    }

    @Test func rejectedSubmissionIsReportedAsNotAccepted() async throws {
        let spy = Spy()
        spy.accept = false
        let handler = makeHandler(spy: spy)

        let result = try await handler.handle(request(.text, text: "hello"))

        #expect(field(result, "accepted") == .bool(false))
    }

    @Test func blankTextIsRefusedBeforeTouchingTheInputPath() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy)

        await #expect(throws: PickyDebugControlError.textRequired) {
            try await handler.handle(request(.text, text: "   "))
        }
        #expect(spy.submitted.isEmpty)
    }

    @Test func oversizedTextIsRefusedBeforeTouchingTheInputPath() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy)
        let oversized = String(repeating: "a", count: PickyDebugControlHandler.textCharacterLimit + 1)

        await #expect(throws: PickyDebugControlError.textTooLong(limit: PickyDebugControlHandler.textCharacterLimit)) {
            try await handler.handle(request(.text, text: oversized))
        }
        #expect(spy.submitted.isEmpty)
    }

    @Test func liveVoiceInputBlocksInjectionWithAnExplicitBusyError() async {
        let spy = Spy()
        spy.busyReason = "push-to-talk is held"
        let handler = makeHandler(spy: spy)

        await #expect(throws: PickyDebugControlError.busy("push-to-talk is held")) {
            try await handler.handle(request(.text, text: "hello"))
        }
        #expect(spy.submitted.isEmpty)
    }

    @Test func pushToTalkPressAndReleaseDriveTheSharedShortcutPath() async throws {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }
        let spy = Spy()
        let handler = makeHandler(spy: spy, recorder: recorder)

        let pressed = try await handler.handle(request(.pttPress))
        let startedInputID = try #require(spy.activeVoiceInputID)
        #expect(field(pressed, "pushToTalkHeld") == .bool(true))
        #expect(field(pressed, "inputStarted") == .bool(true))
        // The reply names the production voice input, not a debug-only handle.
        #expect(field(pressed, "inputId") == .string(startedInputID.uuidString))

        let released = try await handler.handle(request(.pttRelease))
        #expect(field(released, "pushToTalkHeld") == .bool(false))
        // Release correlates to the same input the press started, so the
        // transcript and reply that follow stay on one timeline.
        #expect(field(released, "inputId") == .string(startedInputID.uuidString))
        #expect(spy.pushToTalk == [.press, .release])

        await recorder.flush()
        let edges = published.filter { $0.name == "debug.pushToTalk" }
        #expect(edges.count == 2)
        #expect(edges.allSatisfy { $0.inputId == startedInputID.uuidString })
        #expect(edges.map(\.outcome) == ["press", "release"])
    }

    @Test func aPressTheAppRefusesIsNotReportedAsAStartedRecording() async throws {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }
        let spy = Spy()
        // The production press path swallows the edge while an unrelated
        // dictation is finishing: the hold flag flips, no input is created.
        spy.startsRecording = false
        let handler = makeHandler(spy: spy, recorder: recorder)

        let pressed = try await handler.handle(request(.pttPress))
        await recorder.flush()

        #expect(field(pressed, "inputStarted") == .bool(false))
        #expect(field(pressed, "inputId") == .null)
        let edge = try #require(published.first { $0.name == "debug.pushToTalk" })
        #expect(edge.outcome == "pressWithoutInput")
        #expect(edge.inputId == nil)
    }

    @Test func aPressDoesNotAdoptAnOlderVoiceInputAsItsOwn() async throws {
        let spy = Spy()
        let stale = UUID()
        spy.activeVoiceInputID = stale
        spy.startsRecording = false
        let handler = makeHandler(spy: spy)

        let pressed = try await handler.handle(request(.pttPress))

        // A leftover id from a previous turn is not evidence that this press
        // started anything.
        #expect(field(pressed, "inputStarted") == .bool(false))
        #expect(field(pressed, "inputId") == .null)
    }

    @Test func duplicatePushToTalkEdgesFailLoudlyInsteadOfSilentlyNoOping() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy)

        await #expect(throws: PickyDebugControlError.pushToTalkNotHeld) {
            try await handler.handle(request(.pttRelease))
        }

        spy.held = true
        await #expect(throws: PickyDebugControlError.pushToTalkAlreadyHeld) {
            try await handler.handle(request(.pttPress))
        }
        #expect(spy.pushToTalk.isEmpty)
    }

    @Test func snapshotCarriesItsSchemaVersion() async throws {
        let handler = makeHandler(spy: Spy())

        let result = try await handler.handle(request(.snapshot))

        #expect(field(result, "schemaVersion") == .number(1))
    }
}

/// Drives the real interaction reducer so the trace is produced by the same
/// policy a typed message goes through, not by a debug-only shortcut.
@MainActor
struct PickyDebugProductionTracePathTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func context(id: String) -> PickyContextPacket {
        PickyContextPacket(
            id: id,
            source: "text",
            capturedAt: baseDate,
            transcript: "deploy the thing",
            selectedText: nil,
            cwd: "/tmp/project",
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<50 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(predicate())
    }

    @Test func injectedTextIsTracedFromInputThroughContextToTheReply() async throws {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }
        let coordinator = PickyInteractionCoordinator(
            runtime: PickyInteractionRuntime(),
            envelopeMaker: PickyInteractionStaticEnvelopeMaker()
        )
        coordinator.onEventTraced = { recorder.recordInteraction($0) }

        let inputID = UUID()
        let packet = context(id: "ctx-debug")
        recorder.bindInjection(commandId: "cmd-debug-1", inputID: inputID)

        coordinator.accept(
            .textSubmitted(text: "deploy the thing", inputID: inputID),
            correlation: PickyInteractionCorrelation(inputID: inputID, source: .text)
        )
        coordinator.accept(
            .textContextCaptured(inputID: inputID, context: packet),
            correlation: PickyInteractionCorrelation(inputID: inputID, contextID: packet.id, source: .text)
        )
        coordinator.accept(
            .textSubmissionAccepted(contextID: packet.id, inputID: inputID),
            correlation: PickyInteractionCorrelation(inputID: inputID, contextID: packet.id, source: .text)
        )
        // The reply arrives knowing only the context id, as it does in production.
        coordinator.accept(
            .quickReply(
                contextID: packet.id,
                text: "deployed",
                originSource: .text,
                replyKind: .main,
                sessionID: nil,
                inputID: nil
            ),
            correlation: PickyInteractionCorrelation(contextID: packet.id, source: .agent)
        )

        try await waitUntil { published.count >= 4 || recorder.pendingCount >= 4 }
        await recorder.flush()

        let names = published.map(\.name)
        #expect(names.contains("interaction.textSubmitted"))
        #expect(names.contains("interaction.textContextCaptured"))
        #expect(names.contains("interaction.textSubmissionAccepted"))
        #expect(names.contains("interaction.quickReply"))
        // Correlation is by identity: the reply never saw the input id, yet it
        // still resolves to the command that injected the text.
        #expect(published.allSatisfy { $0.commandId == "cmd-debug-1" })
        let reply = try #require(published.first { $0.name == "interaction.quickReply" })
        #expect(reply.contextId == "ctx-debug")
        #expect(reply.previousState?.contains("waitingForAgent") == true)
        for record in published {
            let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            #expect(!json.contains("deploy the thing"))
            #expect(!json.contains("deployed"))
        }
    }

    @Test func ordinaryInputIsTracedWithoutAnyDebugCommand() async throws {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }
        let coordinator = PickyInteractionCoordinator(
            runtime: PickyInteractionRuntime(),
            envelopeMaker: PickyInteractionStaticEnvelopeMaker()
        )
        coordinator.onEventTraced = { recorder.recordInteraction($0) }
        let inputID = UUID()

        coordinator.accept(
            .voicePressed(targetSessionID: "session-7"),
            correlation: PickyInteractionCorrelation(inputID: inputID, sessionID: "session-7", source: .voice)
        )

        try await waitUntil { published.count >= 1 || recorder.pendingCount >= 1 }
        await recorder.flush()

        let record = try #require(published.first { $0.name == "interaction.voicePressed" })
        #expect(record.commandId == nil)
        #expect(record.sessionId == "session-7")
        #expect(record.inputId == inputID.uuidString)
        #expect(record.modality == .audio)
        #expect(record.state?.contains("voiceListening") == true)
    }

    @Test func aVoicePressWithoutACallerInputIDStillCarriesTheRecordingItStarted() async throws {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }
        let coordinator = PickyInteractionCoordinator(
            runtime: PickyInteractionRuntime(),
            envelopeMaker: PickyInteractionStaticEnvelopeMaker()
        )
        coordinator.onEventTraced = { recorder.recordInteraction($0) }

        // `voicePressed` carries no input id of its own; the reducer mints one.
        coordinator.accept(.voicePressed(targetSessionID: nil), correlation: PickyInteractionCorrelation(source: .voice))

        try await waitUntil { published.count >= 1 || recorder.pendingCount >= 1 }
        await recorder.flush()

        let record = try #require(published.first { $0.name == "interaction.voicePressed" })
        let listening = try #require(coordinator.projection.state.debugActiveInputID)
        #expect(record.inputId == listening.uuidString)
    }

    /// The push-to-talk shape `picky-debug` actually drives: the handler takes
    /// both edges, the production state machine owns the input identity, and
    /// the transcript/context/reply that follow must land on one timeline.
    @Test func pushToTalkEdgesCorrelateTheWholeVoiceTurnToTheirCommands() async throws {
        var published: [PickyDebugTraceRecord] = []
        let recorder = PickyDebugTraceRecorder { published.append(contentsOf: $0); return true }
        let coordinator = PickyInteractionCoordinator(
            runtime: PickyInteractionRuntime(),
            envelopeMaker: PickyInteractionStaticEnvelopeMaker()
        )
        coordinator.onEventTraced = { recorder.recordInteraction($0) }
        var held = false
        var activeInputID: UUID?

        let handler = PickyDebugControlHandler(
            dependencies: PickyDebugControlHandler.Dependencies(
                snapshot: { PickyDebugAppSnapshot.unavailable },
                busyReason: { _ in nil },
                submitText: { _, _ in false },
                controlPushToTalk: { action in
                    switch action {
                    case .press:
                        held = true
                        // Mirrors `handleShortcutTransition(.pressed)`: the id is
                        // minted before the event reaches the coordinator.
                        let inputID = UUID()
                        activeInputID = inputID
                        coordinator.accept(
                            .voicePressed(targetSessionID: nil),
                            correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                        )
                    case .release:
                        held = false
                        guard let inputID = activeInputID else { return }
                        coordinator.accept(
                            .voiceReleased(inputID: inputID),
                            correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                        )
                    }
                },
                isPushToTalkHeld: { held },
                activeVoiceInputID: { activeInputID }
            ),
            recorder: recorder
        )

        _ = try await handler.handle(PickyDebugAppRequest(
            requestId: "req-press", commandId: "cmd-press", action: .pttPress, text: nil
        ))
        let inputID = try #require(activeInputID)
        _ = try await handler.handle(PickyDebugAppRequest(
            requestId: "req-release", commandId: "cmd-release", action: .pttRelease, text: nil
        ))

        // The dictation provider and the agent finish the turn.
        let packet = context(id: "ctx-voice")
        coordinator.accept(
            .transcriptFinal(text: "deploy the thing", inputID: inputID),
            correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
        )
        coordinator.accept(
            .voiceContextCaptured(inputID: inputID, transcript: "deploy the thing", context: packet, targetSessionID: nil),
            correlation: PickyInteractionCorrelation(inputID: inputID, contextID: packet.id, source: .voice)
        )
        coordinator.accept(
            .quickReply(
                contextID: packet.id,
                text: "deployed",
                originSource: .voice,
                replyKind: .main,
                sessionID: nil,
                inputID: nil
            ),
            correlation: PickyInteractionCorrelation(contextID: packet.id, source: .agent)
        )

        try await waitUntil { published.contains { $0.name == "interaction.quickReply" } }
        await recorder.flush()

        let names = published.map(\.name)
        #expect(names.contains("interaction.voicePressed"))
        #expect(names.contains("interaction.voiceReleased"))
        #expect(names.contains("interaction.transcriptFinal"))
        #expect(names.contains("interaction.voiceContextCaptured"))
        // The press owns the input, so the turn resolves to the command that
        // started it even though the reply only ever saw the context id.
        let interactionRecords = published.filter { $0.name.hasPrefix("interaction.") }
        #expect(interactionRecords.allSatisfy { $0.commandId == "cmd-press" })
        let reply = try #require(published.first { $0.name == "interaction.quickReply" })
        #expect(reply.contextId == "ctx-voice")
        // The release edge links its own command to the same input, which is
        // what lets `timeline --command cmd-release` reach the whole turn.
        let releaseEdge = try #require(published.last { $0.name == "debug.pushToTalk" })
        #expect(releaseEdge.commandId == "cmd-release")
        #expect(releaseEdge.inputId == inputID.uuidString)
        for record in published {
            let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            #expect(!json.contains("deploy the thing"))
            #expect(!json.contains("deployed"))
        }
    }
}

@MainActor
struct PickyDebugProtocolWireTests {
    @Test func decodesDebugAppRequestedEvent() throws {
        let json = Data("""
        {
          "id": "event-debug-app",
          "protocolVersion": "2026-08-25",
          "timestamp": "2026-05-01T00:00:00.000Z",
          "type": "debugAppRequested",
          "requestId": "debug-request-1",
          "commandId": "cmd-debug-1",
          "action": "text",
          "text": "run the build"
        }
        """.utf8)

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)

        guard case .debugAppRequested(let request) = envelope.event else {
            Issue.record("Expected debugAppRequested event")
            return
        }
        #expect(request.requestId == "debug-request-1")
        #expect(request.commandId == "cmd-debug-1")
        #expect(request.action == .text)
        #expect(request.text == "run the build")
    }

    @Test func publishDebugTraceCommandRoundTripsItsRecords() throws {
        let command = PickyCommandEnvelope(
            type: .publishDebugTrace,
            records: [
                PickyDebugTraceRecord(
                    source: .app,
                    name: "interaction.textSubmitted",
                    timestamp: Date(timeIntervalSince1970: 1_767_225_600),
                    monotonicMs: 1234.5,
                    inputId: "11111111-1111-1111-1111-111111111111",
                    commandId: "cmd-debug-1",
                    state: "in=textSubmitting out=idle overlay=hidden",
                    modality: .text,
                    textLength: 13
                ),
            ]
        )

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: data)

        #expect(decoded.type == .publishDebugTrace)
        #expect(decoded.records == command.records)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(object["records"] as? [[String: Any]])
        let first = try #require(records.first)
        #expect(first["source"] as? String == "app")
        #expect(first["textLength"] as? Int == 13)
        // Absent optional fields must not be sent as nulls.
        #expect(first.keys.contains("sessionId") == false)
    }

    @Test func debugCommandsStayOutOfOrdinaryAppTraffic() {
        // The app only ever originates these two; `debugApp` and `readDebugTrace`
        // exist so shared fixtures and logs decode on both ends.
        #expect(PickyCommandType(rawValue: "completeDebugApp") == .completeDebugApp)
        #expect(PickyCommandType(rawValue: "publishDebugTrace") == .publishDebugTrace)
        #expect(PickyCommandType(rawValue: "debugApp") == .debugApp)
        #expect(PickyCommandType(rawValue: "readDebugTrace") == .readDebugTrace)
    }
}
