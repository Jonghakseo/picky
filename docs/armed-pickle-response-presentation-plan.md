# Armed Pickle Response Presentation Plan

_Status: proposed; technical review complete, implementation not started_

_Last updated: 2026-07-19_

## Summary

When a one-shot armed Pickle receives a screenshot-backed PTT or Quick Input message, Picky currently clears `screenContextTargetSessionID` as soon as the command is accepted. `BlueCursorView` uses that same value to choose between the Pickle glyph and the Picky mascot, so the cursor changes back to Picky before the Pickle's visual DSL response and TTS finish.

This plan separates two concepts that are currently coupled:

1. **Routing armed state** — which Pickle may receive the next input.
2. **Response presentation state** — which actor produced the response currently shown or spoken at the cursor.

A one-shot routing target remains one-shot and is consumed immediately after successful dispatch. A separate turn-scoped Pickle response presentation lease keeps the Pickle cursor glyph visible until the matching visual response producer has settled and all speech for that response has drained.

The core invariant is:

> Routing authority is consumed at dispatch; response provenance survives until local presentation completes.

## Design Decision Card

- **User goal:** recognize that the current visual narration and spoken response came from the armed Pickle rather than the main Picky agent.
- **Target surface/component:** cursor mascot in `BlueCursorView`; no new panel or bubble.
- **First-glance information:** actor provenance — Pickle while that response is being presented, Picky otherwise.
- **Primary action:** not applicable; this is transient response status, not a control.
- **Secondary action:** existing annotation dismiss control remains available after narration settles.
- **Session/status semantics:** routing `armed` and response `presenting` are separate states. The Pickle glyph may mean `presenting` after one-shot routing authority has been consumed.
- **Required states:**
  - Rest: existing Picky mascot unless a routing target remains armed.
  - Listening/processing/responding: reuse the existing Pickle glyph voice-state color and motion mapping.
  - Completed: return to Picky after producer settlement and matching speech drain.
  - Failed/cancelled/preempted: return through the same context-scoped cleanup policy.
  - Hover/pressed/focused/disabled: not applicable because the cursor mascot is not an interactive control.
- **Token plan:** reuse existing cursor colors, size, glow, shape, and motion; add no color, typography, spacing, material, or elevation token.
- **Native macOS behavior:** preserve system cursor visibility mirroring, click-through overlays, multi-display uniqueness, and Quick Input suppression.
- **Accessibility/appearance:** preserve Reduce Motion behavior, hidden-idle-cursor preference, light/dark adaptation, and non-color actor distinction through glyph shape.
- **Existing behavior to preserve:** one-shot and sticky routing, shared TTS queue ordering, annotation recovery/dismissal, pointer navigation, and no running-app restart.
- **Risks and validation:** context races, stale same-session events, provider differences, empty DSL, and preemption require state-machine and runtime verification.
- **Explicit exception:** the Pickle glyph can remain visible after the true one-shot armed routing state is consumed because it represents response provenance during that interval.

## Product contract

### Required behavior

For an armed Pickle dispatch with `visualDslEnabled == true`:

- Show the existing Pickle cursor glyph while the request is processing.
- Keep the Pickle glyph during ordinary narration, visual DSL narration, and TTS playback for that response.
- For incremental TTS, return to the Picky mascot only after the last queued sentence finishes or fails.
- For non-incremental TTS, return only after the clean final reply finishes or fails.
- With TTS disabled, return when the visual producer settles because there is no speech queue to drain.
- For visual-only or clean-empty DSL output, return when the producer settles even if no `quickReply` exists.
- Keep annotation geometry and its explicit dismiss lifecycle independent from the cursor glyph lifecycle.
- Preserve sticky armed behavior: sticky targets remain routeable until the user explicitly changes them or a hard failure removes them.

### One-shot routing behavior

A one-shot target must not become temporarily sticky while its response is speaking.

If a second PTT or Quick Input starts during the first response:

- the previously consumed one-shot target must not receive it implicitly;
- normal routing rules apply to the new input;
- starting the new input preempts the old response presentation lease;
- if a sticky Pickle is still armed, the new input may continue routing to that sticky target.

### Meaning of the Pickle glyph

During response playback, the Pickle glyph means **"this response is from a Pickle"**, not **"the next input will route to this Pickle."**

If the Dock or Conversation Header later needs to keep a visible state during response playback, it should present a distinct `responding`/`presenting` state derived from the response lease. It must not retain real routing authority merely to preserve an armed visual.

## Current behavior and root cause

### Shared state currently owns three responsibilities

`screenContextTargetSessionID` currently controls:

- PTT and Quick Input routing in `Picky/CompanionManager.swift`;
- one-shot/sticky armed presentation in the HUD;
- cursor mascot selection, shadow, compact placement, and visibility in `Picky/Overlay/BlueCursorView.swift`.

`BlueCursorView.cursorMascot` already renders `PickleTargetCursorMascotView` whenever `screenContextTargetSessionID != nil`. No new glyph or visual token is required.

### One-shot clear happens before response presentation

The following paths call `clearScreenContextTargetIfCurrent` immediately after send success:

- direct voice routing through `routeVoiceTranscript`;
- interaction-reducer voice routing through `runFollowUpPickleEffect`;
- armed Quick Input through `sendPickleMessageFromInput`.

This preserves one-shot routing, but it also removes the only signal that selects the Pickle cursor glyph.

### Existing response metadata is sufficient for provenance

Pickle visual narration events already carry:

- `contextId`;
- `sessionId`;
- visual segment identity with `turnToken` for prepared/sentence/committed events.

The app therefore does not need to infer Pickle provenance from text, event timing, or the currently armed target.

### Existing completion signals are insufficient individually

- `quickReply` is not TTS completion; incremental speech may continue after it.
- A single `speechFinished` is not response completion; more sentences may remain queued.
- Global speech queue emptiness is too broad because unrelated contexts can share the queue.
- TTS-off produces no speech completion callback.
- A visual-only response may produce no clean `quickReply`.
- Session terminal status may arrive before the final `quickReply`, and session identity alone cannot protect against stale events from an older turn in the same Pickle.

## Goals

1. Keep the existing Pickle glyph visible for the full armed visual-response presentation.
2. Preserve one-shot and sticky routing semantics exactly.
3. Make response completion context- and turn-scoped.
4. Support incremental, non-incremental, disabled, failed, and preempted TTS.
5. Handle clean-empty and visual-only DSL output without a stuck cursor.
6. Prevent stale completion from clearing a newer target or presentation lease.
7. Keep state-transition policy in the interaction reducer rather than in SwiftUI conditionals.
8. Reuse the existing glyph, colors, animation, accessibility behavior, and annotation lifecycle.

## Non-goals

- Do not redesign the Pickle cursor glyph.
- Do not change annotation colors, labels, geometry, spotlight, or dismiss controls.
- Do not make one-shot armed mode route multiple messages.
- Do not retain the Pickle glyph until annotations are manually dismissed.
- Do not derive response source from the current selected/hovered Pickle.
- Do not add provider-specific completion heuristics in `BlueCursorView`.
- Do not restart the running Picky app during implementation or automated validation.

## Architecture principles

### Routing and presentation are separate leases

The routing target answers:

> Where may the next user input go?

The presentation lease answers:

> Which actor owns the response currently being presented?

They have different creation, consumption, and cancellation rules and must not share one mutable flag.

### Agentd owns producer settlement

Only agentd knows when the Pickle parser has flushed all source deltas, finalized visual segments, emitted the final clean reply when one exists, and ended the active visual lease.

Agentd must emit an explicit turn-scoped settlement barrier. Swift must not infer this barrier from session status or silence.

### The reducer owns presentation settlement

The interaction reducer already owns:

- active and queued speech;
- speech finish/failure/preemption;
- progressive visual narration state;
- TTS-off and minimum-display transitions.

It should therefore decide when a Pickle response presentation lease can end. `CompanionManager` executes effects and publishes the resulting projection; `BlueCursorView` only renders the projection.

### Annotation lifetime remains independent

The Pickle glyph lease ends when narration presentation ends. Revealed annotations may remain visible and dismissible afterward according to the existing annotation scene policy.

## Domain model

Add a turn-scoped state to the interaction domain. Names may be adjusted during implementation, but the responsibilities must remain explicit.

```swift
struct PickyPickleResponsePresentation: Equatable, Codable {
    let sessionID: String
    let contextID: String
    var turnToken: String?
    var producerSettled: Bool
}
```

The state does not need a duplicate speech counter. Matching speech can be derived from existing canonical state:

- active `.speaking` output for `contextID`;
- `queuedSpeechReplies` entries for `contextID`.

If implementation proves this derivation ambiguous, add a context-scoped set of speech IDs in the reducer, not in `CompanionManager` or the view.

### Presentation states

```text
none
  └─ visual armed dispatch accepted
       ▼
active / producer running
  ├─ narration and visual events bind the turn token
  ├─ speech entries may be active or queued
  └─ explicit agentd settlement barrier
       ▼
active / producer settled
  ├─ matching speech remains → keep Pickle glyph
  └─ no matching speech      → finish lease
       ▼
none
```

### Cursor projection

Expose a pure projection such as:

```swift
usesPickleCursorMascot =
    screenContextTargetSessionID != nil
    || activePickleResponsePresentation != nil
```

`BlueCursorView` currently checks `screenContextTargetSessionID` in four places. Replace those checks with one projected/computed policy so glyph selection, outer shadow, compact placement, and forced visibility cannot drift apart.

## Wire protocol

Add an explicit event emitted exactly once for every activated Pickle visual lease, including clean-empty output.

Proposed shape:

```json
{
  "type": "pickleVisualTurnSettled",
  "contextId": "context-id",
  "contextGeneration": 0,
  "turnToken": "pickle-visual-lease-id",
  "sessionId": "pickle-session-id",
  "outcome": "completed"
}
```

Suggested outcomes:

- `completed`
- `failed`
- `cancelled`
- `waitingForInput`
- `replaced`

The event is a producer barrier, not a TTS completion event.

### Event ordering

For a normal response with clean text:

```text
prepared / sentence / committed events
quickReply (if clean text is non-empty)
pickleVisualTurnSettled
```

For clean-empty visual-only output:

```text
prepared / committed events
pickleVisualTurnSettled
```

For failure, cancellation, replacement, or waiting-for-input:

```text
flush parser and committed visual events when safe
pickleVisualTurnSettled(outcome)
deactivate agentd lease
```

Transient busy statuses that are intentionally ignored must not settle the lease.

### Protocol contract updates

A protocol change must update all contract owners:

- `agentd/src/protocol.ts`
- `Picky/PickyAgentProtocol.swift`
- `contracts/protocol/pickle-visual-turn-settled.event.json` or equivalent fixture
- `agentd/src/protocol.test.ts`
- `PickyTests/ProtocolContractTests.swift`

## Agentd design

### Pickle visual coordinator

Update `agentd/src/application/pickle-visual-dsl-coordinator.ts` so each active lease records whether settlement has already been emitted.

Required behavior:

- emit the barrier after parser and segment finalization;
- emit after `quickReply` when clean text exists;
- emit even when normalized clean text is empty;
- make settlement idempotent;
- include context, generation, session, and turn token;
- use deactivation as a fallback only when no prior settlement was emitted.

### Runtime event handler

`agentd/src/application/runtime-event-handler.ts` currently distinguishes terminal, waiting-for-input, and ignored transient busy statuses. The coordinator must receive a definitive turn outcome after assistant message finalization for every real turn boundary.

Do not treat raw `sessionUpdated` ordering as the app's presentation-completion contract.

### Session supervisor

`agentd/src/session-supervisor.ts` should broadcast the new event through the existing Pickle visual coordinator bridge and preserve event order.

## Swift app design

### Dispatch start

When `prepareArmedPickleVisualDslContext` returns `true`, start a local presentation lease using the captured `context.id` and target `sessionID`.

Start the lease before or atomically with command dispatch so the Pickle glyph does not flicker back to Picky while waiting for the first daemon narration event.

On send success:

- consume the one-shot routing target using the current behavior;
- retain the independent presentation lease;
- leave sticky routing state unchanged.

On send failure or rejection:

- clear the attempted presentation lease immediately;
- retain existing visible error behavior;
- clear one-shot routing according to the current failure policy.

Apply this consistently to:

- direct voice routing;
- interaction effect voice routing;
- armed Quick Input;
- follow-up and steer dispatch modes.

### Interaction events

Add explicit local/domain events such as:

- `pickleResponsePresentationStarted(sessionID:contextID:)`
- `pickleVisualTurnSettled(sessionID:contextID:turnToken:outcome:)`
- `pickleResponsePresentationCancelled(contextID:reason:)`

Exact event names may differ, but lifecycle mutations must remain reducer-owned.

### Settlement rule

A lease may finish only when:

```text
producerSettled == true
AND
no active speech output matches lease.contextID
AND
no queued speech reply matches lease.contextID
```

Call the settlement helper after every reducer transition that may change those conditions:

- producer-settled event;
- speech finished;
- speech failed;
- minimum-display completion;
- speech preemption;
- quick reply replacement;
- session reset/termination;
- connection loss.

### Provider behavior

#### Incremental provider

- Every narration sentence enters the existing queue.
- The producer barrier may arrive while one or more sentences remain active/queued.
- Keep the Pickle glyph until the last matching sentence finishes or fails.

#### Non-incremental provider

- Progressive text/visual events do not enqueue sentence audio.
- Final `quickReply` starts one full clean-reply speech before the settlement barrier.
- Keep the Pickle glyph until that final speech finishes or fails.

#### TTS off

- No matching speech exists.
- End the presentation lease immediately when the producer barrier arrives.

#### Provider failure/watchdog

- Treat speech failure as a drain event for that speech ID.
- If the producer has settled and no matching speech remains, end the lease.

### Preemption and supersession

Starting a new PTT or Quick Input must cancel/supersede the old response presentation in the same state-machine transition that preempts its speech.

A newer presentation lease follows latest-context-wins behavior. Late events for an older `contextID` or mismatched `turnToken` must be ignored and must never clear the newer lease.

### Manual armed changes

- Manual disarm changes routing state but does not rewrite the immutable source of an already playing response.
- Arming another Pickle does not allow the old response's settlement event to clear the new target.
- Sticky armed state is never cleared by response presentation settlement.
- Re-arming the same session is safe because settlement is context/turn-scoped, not guarded by session ID alone.

### Hard cleanup

Clear or invalidate presentation leases on:

- send rejection/failure;
- user speech/text preemption;
- session abort/delete/replacement when matching;
- main interaction reset;
- daemon disconnect;
- unrecoverable protocol error;
- app-side context replacement that invalidates the visual turn.

Session terminal status may remain a watchdog/backstop for diagnostics, but it is not the primary success barrier.

## Failure handling and race safety

### Empty visual response

The explicit producer barrier prevents a permanent Pickle glyph when DSL stripping leaves no clean prose and therefore no `quickReply`.

### Terminal before final reply

Do not clear on session terminal status alone. The protocol barrier is ordered after final clean-reply emission, so non-incremental TTS can start before the producer is marked settled.

### Speech finishes before producer settles

Keep the lease active. When the producer barrier later arrives, it observes no matching speech and finishes immediately.

### Producer settles before speech finishes

Mark `producerSettled = true` but retain the lease until matching active and queued speech drain.

### Unrelated shared speech

Do not wait for the global speech queue to become empty. Only speech entries with the lease's `contextID` participate in settlement.

### Stale same-session event

Session ID equality is insufficient because one Pickle can accept multiple turns. Require matching context and, once bound, matching turn token.

### Annotation persistence

Do not use `agentAnnotations.isEmpty`, dismiss-control visibility, or scene-recovery expiry as response completion signals.

## File-by-file change map

### Agentd

- `agentd/src/application/pickle-visual-dsl-coordinator.ts`
  - exactly-once producer settlement
  - clean-empty and abnormal outcome handling
- `agentd/src/application/runtime-event-handler.ts`
  - deliver definitive turn outcomes
- `agentd/src/session-supervisor.ts`
  - broadcast the settlement event in order
- `agentd/src/protocol.ts`
  - TypeScript event schema
- `agentd/src/application/pickle-visual-dsl-coordinator.test.ts`
  - event order and empty-output coverage
- `agentd/src/application/runtime-event-handler.test.ts`
  - terminal/waiting/failure ordering
- `agentd/src/protocol.test.ts`
  - protocol validation

### Contracts

- `contracts/protocol/pickle-visual-turn-settled.event.json`
  - canonical event fixture/schema

### Swift app

- `Picky/PickyAgentProtocol.swift`
  - decode the producer barrier
- `Picky/Interaction/PickyInteractionEvent.swift`
  - local start/cancel and protocol settlement events
- `Picky/Interaction/PickyInteractionState.swift`
  - Codable presentation lease with backward-compatible decode default
- `Picky/Interaction/PickyInteractionReducer.swift`
  - lifecycle and context-scoped drain rule
- `Picky/Interaction/PickyInteractionProjection.swift`
  - Pickle mascot presentation projection
- `Picky/CompanionManager.swift`
  - dispatch wiring and effect execution only
- `Picky/Overlay/BlueCursorView.swift`
  - consume one cursor-mascot policy instead of direct armed checks

### Tests and docs

- `PickyTests/PickyCompanionManagerTests.swift`
- `PickyTests/PickyInteractionReducerTests.swift`
- `PickyTests/ProtocolContractTests.swift`
- `PickyTests/PickyCursorPreferenceTests.swift` or a focused pure cursor policy test
- `docs/user-manual.md` after implementation

## Test Plan Card

### Product invariant

An armed visual Pickle response uses the Pickle cursor glyph until its matching local presentation ends, without extending one-shot routing authority.

### Test level

- TypeScript unit tests for producer barrier ordering and exactly-once behavior.
- Swift reducer tests for lease state transitions and race safety.
- CompanionManager tests for PTT/Quick Input dispatch integration.
- Pure projection/policy tests for glyph selection.
- Protocol contract tests on both sides.
- Manual runtime verification for visual timing and appearance.

### Required automated scenarios

1. One-shot PTT dispatch consumes routing immediately but starts presentation.
2. One-shot Quick Input dispatch behaves identically.
3. Sticky dispatch keeps routing after presentation settles.
4. Two-sentence incremental TTS keeps presentation through the second speech.
5. Producer settlement before the last speech does not release early.
6. Speech drain before producer settlement does not release early.
7. Non-incremental final reply keeps presentation through full-reply speech.
8. TTS-off settles immediately at the producer barrier.
9. Clean-empty visual-only output emits a barrier and does not stick.
10. Speech failure/watchdog drains the matching lease.
11. Starting a new input preempts the old lease.
12. Unrelated queued speech does not delay the matching lease.
13. An old context's late barrier does not clear a newer lease.
14. Re-arming the same session is protected by context/turn identity.
15. Manual disarm does not change the source glyph of already playing speech.
16. Send rejection clears presentation immediately.
17. Abort, replacement, reset, and disconnect clear matching state.
18. Existing annotation persistence and dismiss behavior remain unchanged.
19. Hidden-idle-cursor preference still shows the Pickle glyph during active presentation.
20. Reduce Motion keeps a static but semantically correct Pickle glyph.

### Validation commands

```bash
cd agentd && pnpm test
cd agentd && pnpm run lint
cd agentd && pnpm run typecheck
cd agentd && pnpm run build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test \
  -only-testing:PickyTests/PickyCompanionManagerTests \
  -only-testing:PickyTests/PickyInteractionReducerTests \
  -only-testing:PickyTests/ProtocolContractTests
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" build
git diff --check
```

## Implementation sequence

1. Add characterization tests proving current one-shot and sticky routing semantics.
2. Add failing agentd tests for a settlement barrier after non-empty and clean-empty visual turns.
3. Add the protocol contract and exactly-once coordinator implementation.
4. Add the Codable Swift presentation state with backward-compatible defaults.
5. Add reducer start, settle, failure, preemption, and stale-event tests.
6. Wire visual armed dispatches to start presentation while preserving immediate one-shot consumption.
7. Add a pure cursor mascot projection and replace all four direct armed checks in `BlueCursorView`.
8. Add hard-cleanup and latest-context-wins tests.
9. Run targeted tests, full agentd validation, Swift build, and relevant Swift suites.
10. Manually verify the provider matrix without restarting the running app unless explicitly requested.
11. Update the user manual and mark this plan implemented only after automated validation passes.

## Manual acceptance scenarios

### Incremental TTS

1. Arm a one-shot Pickle.
2. Submit screenshot-backed PTT or Quick Input that produces at least two visual sentences.
3. Confirm the Pickle glyph appears during processing.
4. Confirm it remains through both sentence playbacks and annotation reveals.
5. Confirm it changes back to Picky only after the final sentence finishes.
6. During playback, submit a second unarmed input and confirm it does not route to the consumed Pickle.

### Non-incremental TTS

1. Select a provider without incremental playback.
2. Submit an armed visual Pickle request.
3. Confirm progressive visuals can appear while generation continues.
4. Confirm the Pickle glyph remains through the final clean-reply playback.
5. Confirm it changes back only after that playback ends.

### TTS off and visual-only

1. Disable TTS.
2. Submit a response containing visual DSL with no clean prose.
3. Confirm the Pickle glyph remains until the producer barrier.
4. Confirm it returns without waiting for annotation dismissal.

### Sticky and stale events

1. Arm a sticky Pickle and submit a visual request.
2. Confirm the target remains armed after presentation ends.
3. Arm another Pickle while the prior response is still active.
4. Confirm a late finish from the prior context cannot clear or alter the new target.

## Observability

Add structured logs for:

- presentation lease start: session/context;
- turn token binding;
- producer settlement outcome;
- matching active/queued speech count at settlement;
- lease completion reason;
- stale settlement ignored;
- preemption/hard cleanup.

Do not log full response text or screenshot content.

Suggested latency markers:

```text
picklePresentationStarted
pickleProducerSettled
picklePresentationSpeechDrained
picklePresentationFinished
```

## Rollout and rollback

The change is local and protocol-version compatible only after both app and bundled agentd are updated together.

Rollback strategy:

- remove the presentation lease projection;
- restore `BlueCursorView` to armed-target-only mascot selection;
- retain immediate one-shot consumption;
- ignore the new additive settlement event on older app builds through the existing unknown-event behavior.

Do not roll back by delaying `screenContextTargetSessionID` clearing.

## Definition of done

- One-shot routing is still consumed at dispatch.
- Sticky routing remains sticky.
- Armed visual Pickle responses use the Pickle glyph through local presentation completion.
- Incremental, non-incremental, TTS-off, clean-empty, failure, and preemption paths all settle.
- Stale events cannot clear newer routing or presentation state.
- Annotation persistence remains independent.
- Agentd tests, lint, typecheck, and build pass.
- Relevant Swift tests and macOS build pass.
- Manual provider-matrix verification is recorded.
- The running Picky app was not restarted without explicit user approval.

## Technical review record

The design was pressure-reviewed from verifier, reviewer, and challenger perspectives before documentation.

Common conclusions:

- delaying `screenContextTargetSessionID` clearing is incorrect because it changes one-shot routing;
- routing and presentation must be separate turn-scoped leases;
- `quickReply`, terminal session status, a single speech callback, or global queue emptiness are each insufficient alone;
- clean-empty visual turns require an explicit producer barrier;
- completion must be context/turn-scoped and hardened against preemption and re-arm races.

Residual validation risk:

- event ordering and cursor timing still require runtime observation after implementation, especially across incremental, non-incremental, and disabled TTS providers.

## Reference map

- Product and architecture constraints: `AGENTS.md`
- Picky design direction: `design/DESIGN.md`
- State and motion principles: `design/PRINCIPLES.md`
- Cursor response component contract: `design/COMPONENTS.md`
- Reducer ownership and protocol rules: `docs/refactoring-principles.md`
- Existing narration pipeline plan: `docs/visual-narration-segment-plan.md`
- Armed routing orchestration: `Picky/CompanionManager.swift`
- Canonical interaction state: `Picky/Interaction/PickyInteractionState.swift`
- Presentation reducer: `Picky/Interaction/PickyInteractionReducer.swift`
- Cursor rendering: `Picky/Overlay/BlueCursorView.swift`
- Pickle DSL producer: `agentd/src/application/pickle-visual-dsl-coordinator.ts`
