# Visual Narration Segment Plan

_Status: implemented; automated validation complete, manual runtime verification pending_

_Last updated: 2026-07-19_

## Contents

> Line numbers refer to this document revision and should be refreshed whenever sections move.

| Section | Start line |
|---|---:|
| [Approved implementation amendment: sentence-progressive bubbles](#approved-implementation-amendment-sentence-progressive-bubbles) | 35 |
| [Summary](#summary) | 73 |
| [Why this work is needed](#why-this-work-is-needed) | 98 |
| [Product contract](#product-contract) | 154 |
| [Goals](#goals) | 266 |
| [Non-goals](#non-goals) | 278 |
| [Architecture principles](#architecture-principles) | 289 |
| [Latency analysis](#latency-analysis) | 329 |
| [Domain model](#domain-model) | 360 |
| [Wire protocol](#wire-protocol) | 441 |
| [Agentd design](#agentd-design) | 538 |
| [Swift app design](#swift-app-design) | 615 |
| [Failure handling and race safety](#failure-handling-and-race-safety) | 796 |
| [Observability](#observability) | 840 |
| [File-by-file change map](#file-by-file-change-map) | 869 |
| [Test Plan Card](#test-plan-card) | 926 |
| [Implementation sequence](#implementation-sequence) | 996 |
| [Manual acceptance scenarios](#manual-acceptance-scenarios) | 1219 |
| [Rollout and rollback](#rollout-and-rollback) | 1269 |
| [Definition of done](#definition-of-done) | 1290 |
| [Reference map](#reference-map) | 1316 |

## Approved implementation amendment: sentence-progressive bubbles

The implementation includes a follow-up product decision made after this plan was approved: both ordinary main-agent prose and visual narration must appear in the cursor response bubble at least one completed sentence at a time.

This amendment supersedes earlier statements in this document that required a multi-sentence visual segment to remain invisible and immutable until the next visual opener. The canonical segment is still committed at the next opener/turn end, but completed sentences are emitted before that final commit.

The implemented lifecycle is:

```text
visual tag complete       sentence complete         next visual opener / turn end
        │                        │                               │
        ▼                        ▼                               ▼
     prepared  ───────────▶ sentence progress ─────────────▶ committed
 geometry only             immutable sentence event          canonical full text
 validation may start      bubble/visual may activate        expected sentence count
```

Implemented protocol events:

- `mainVisualNarrationSegmentPrepared`
- `mainVisualNarrationSegmentSentence`
- `mainVisualNarrationSegmentCommitted`

Playback behavior:

- Ordinary `mainNarrationChunk` events are emitted and projected even when TTS is disabled or the provider is non-incremental.
- Incremental TTS activates a visual sentence only when the matching speech ID starts, so a prepared future segment cannot overwrite the segment currently being spoken.
- Non-incremental TTS displays visual sentences progressively as generation completes, then clears sentence activation and synthesizes the final full reply once. This supersedes the earlier weighted-FIFO playback activation proposal for non-incremental providers; showing a stale final visual while audio restarts from the beginning is not permitted.
- TTS-off mode displays visual sentences progressively without creating speech effects.
- Annotation `validating`/`suspended` phases hide both the annotation and its active visual narration bubble.

Implementation outcome:

- Agentd parser, segment assembler, supervisor, server, TypeScript schema, fixtures, and tests are implemented.
- Swift protocol decoding, journal-compatible interaction state, reducer transitions, CompanionManager routing, projection, and cursor bubble integration are implemented.
- The implementation reuses the existing response bubble visual style and annotation scene monitor; no new visual tokens, polling worker, real audio dependency, or real ScreenCaptureKit dependency were introduced.

## Summary

Picky's visual overlay DSL already requires the main agent to place a visual tag immediately before the prose that describes it:

```text
[RECT: ...] The first explanation.
[LINE: ...] The second explanation.
```

Today, the visual request and narration are transported and scheduled separately. The cursor response bubble is driven by sentence-sized TTS chunks, while RECT/LINE reveal is driven by weighted timers. As a result, a fast stream can prepare several visuals before the first utterance finishes, generic overlay status text can overwrite the current response bubble, and the bubble has no durable identity connecting it to the visual that is actually active.

This plan introduces a canonical **Visual Narration Segment** owned by `picky-agentd`. One segment binds exactly one RECT/LINE visual to all prose after that tag and before the next visual tag. Picky.app prepares geometry early, commits prose as soon as the next visual opener is lexically known, and activates the visual and response bubble together at the correct playback/reveal point.

The intended lifecycle is:

```text
visual tag complete         next visual opener or turn end        actual playback/reveal point
        │                                  │                                  │
        ▼                                  ▼                                  ▼
     prepared  ───────────────────────▶ committed ───────────────────────▶ activated
 geometry resolved                    prose immutable                     visual + bubble switch
 scene validation starts              TTS may queue                       atomically in reducer
```

## Why this work is needed

### User-visible problem

Given:

```text
[RECT: ...] 설명이 어쩌구.
[RECT: ...] 설명이 저쩌구.
```

Picky should show:

1. First RECT becomes active → response bubble shows only `설명이 어쩌구.`
2. Second RECT becomes active → response bubble switches to only `설명이 저쩌구.`

For multiple sentences, the segment boundary is the next visual tag, not a sentence terminator:

```text
[RECT: ...] 첫 문장. 둘째 문장.
[LINE: ...] 다음 설명.
```

The RECT bubble must show `첫 문장. 둘째 문장.` as one immutable unit.

### Current architectural gap

The current pipeline has no stable visual–narration link:

```text
agent assistant delta
  ├─ AnnotationDslParser streamItems
  ├─ mainNarrationChunk(text only)
  └─ pointerOverlayRequested / annotationOverlayRequested(geometry only)

Picky.app
  ├─ narration chunk → output.speaking → cursor response bubble
  ├─ annotation request → weighted reveal timer
  └─ pointer request → pointer animation/navigation bubble
```

Relevant code:

- Source-order parser: `agentd/src/domain/annotation-dsl.ts`
- Narration sentence chunking: `agentd/src/domain/narration-sentence-chunker.ts`
- DSL orchestration: `agentd/src/session-supervisor.ts`
- TypeScript wire schema: `agentd/src/protocol.ts`
- Swift wire decoding: `Picky/PickyAgentProtocol.swift`
- Canonical interaction state: `Picky/Interaction/PickyInteractionState.swift`
- Reducer and reveal timing: `Picky/Interaction/PickyInteractionReducer.swift`
- Projection into bubble text: `Picky/Interaction/PickyInteractionProjection.swift`
- Side effects and TTS orchestration: `Picky/CompanionManager.swift`
- Active cursor response bubble: `Picky/Overlay/BlueCursorView.swift`

The current sentence chunk is not sufficient as a visual segment because one visual may have multiple sentences. Re-parsing text in Swift is not possible because the DSL has already been removed from clean prose before the app receives narration.

## Product contract

### Segment boundaries

Visual boundary verbs:

- `RECT`
- `LINE`

Transparent selector:

- `SCREEN` changes the selected screenshot for subsequent tags.
- `SCREEN` does not close or open a narration segment.

A segment starts after a valid RECT/LINE tag and ends immediately before the next RECT/LINE opener, or at main-turn completion.

### Early opener boundary

Do not wait for the next tag's closing `]` or complete coordinate arguments before committing the previous segment.

The previous segment becomes immutable as soon as the parser recognizes a complete known visual opener, including its colon:

```text
[RECT:
[LINE:
```

The recognition must use the same case/whitespace healing rules as the existing opener grammar. Examples that establish a boundary:

```text
[RECT:
[ Rect :
```

Prefixes that are not yet unambiguous do not establish a boundary:

```text
[
[RE
[POI
```

This is a parser-level lexical boundary, not UI string matching.

### Examples

#### Normal sequence

```text
[RECT: id=A ...] A 첫 문장. A 둘째 문장. [LINE:
```

At the `[LINE:` opener:

- Commit A with prose `A 첫 문장. A 둘째 문장.`
- Begin processing A immediately.
- Continue buffering the incomplete LINE tag until it is valid or dropped.

#### Split delta

```text
Delta 1: "[RECT: ...] 설명입니다. [LI"
Delta 2: "NE: x1=..."
```

The previous RECT segment is not committed at `[LI`. It is committed once delta 2 makes `[LINE:` unambiguous.

#### SCREEN selector

```text
[RECT: ...] 설명 A. [SCREEN: id=secondary] 계속 A. [LINE: ...] 설명 B.
```

`SCREEN` does not split A. It only changes the screen snapshot captured by the following LINE.

#### Consecutive visual tags

```text
[RECT: ...][LINE: ...] 설명 B.
```

The RECT segment is empty:

- Keep the RECT visual request.
- Do not synthesize fallback prose.
- Do not show a response bubble for the empty segment.
- Do not borrow LINE prose for RECT.

#### Malformed known visual tag

```text
[RECT: ...] 설명 A. [LINE: malformed] orphan prose.
```

The `[LINE:` opener is still a hard barrier:

- Commit A at the opener.
- Drop the malformed LINE using the existing parser diagnostics.
- Do not attach `orphan prose.` back to A.
- Treat subsequent prose as ordinary/orphan narration until another valid visual tag opens a segment.

#### Last segment

```text
[RECT: ...] 마지막 설명.
```

No later opener exists, so commit the segment during main-turn finalization before `quickReply` / `mainTurnSettled` is emitted.

## Goals

1. Bind every DSL RECT/LINE annotation to a stable narration segment in agentd.
2. Show only the active segment's prose in the cursor response bubble.
3. Switch the visual and bubble in one reducer transition.
4. Prevent a future segment arriving early from overwriting the currently active bubble.
5. Preserve incremental and non-incremental TTS behavior without duplicate playback.
6. Preserve annotation scene validation, suspension, restoration, final-drain, and explicit-dismiss policies.
7. Keep explicit pointer/annotation tool requests working without narration metadata.
8. Keep the full clean assistant reply and transcript unchanged.
9. Add deterministic tests without real ScreenCaptureKit, Accessibility, audio, network, or the running Picky app.

## Non-goals

- Do not redesign annotation visuals, labels, colors, spotlight, or geometry.
- Do not add a new bubble style.
- Do not expose raw DSL in the transcript or UI.
- Do not change Pi intent interpretation beyond clarifying the existing tag-before-prose prompt contract.
- Do not make remote TTS providers perform multiple network requests unless they already opt into incremental playback.
- Do not restart the running Picky app during implementation or automated validation.
- Do not revive the currently unused `CompanionResponseOverlayManager` streaming panel as a second state owner.
- Do not add URL semantics or browser-specific annotation validation.

## Architecture principles

### Agentd owns segmentation

Only agentd still has the original interleaved DSL/prose source order. Therefore:

- agentd defines segment boundaries;
- Swift consumes segment identities and immutable prose;
- Swift must not infer association from event arrival timing or text equality.

### Reducer owns activation

Follow `docs/refactoring-principles.md`:

```text
wire event → CompanionManager adapter → reducer event → state + effects → UI projection
```

`CompanionManager` resolves geometry and executes TTS/timer effects. It must not decide which segment is active or write bubble text opportunistically.

### Prepare early; activate late

To minimize latency while preserving exact prose grouping:

- Prepare geometry as soon as the visual tag is complete.
- Commit prose at the next known visual opener or turn end.
- Activate only when playback/reveal reaches the segment.

Preparation must not change visible UI.

### One active visual narration bubble

The standard cursor response bubble in `BlueCursorView` remains the presentation component. The active segment is a new canonical text source, not a new overlapping bubble.

## Latency analysis

### Unavoidable cost

With the contract “all prose until the next visual tag,” the complete segment cannot be known at the first sentence boundary.

For an incremental provider, added first-playback latency is approximately:

```text
time(next visual opener or turn completion) - time(first sentence completion)
```

Consequences:

- One short sentence followed immediately by another visual tag: usually minimal added delay.
- Multiple sentences in one segment: first playback waits for the remaining segment prose.
- Last/only visual segment: waits for main-turn finalization after prose generation.

### Latency recovered by this plan

- Commit at `[RECT:` / `[LINE:` rather than waiting for the full next tag.
- Prepare geometry and begin annotation scene validation while prose is still streaming.
- Let segment A play while the model continues generating and preparing segment B.
- Keep non-incremental providers on their existing final-full-reply synthesis path.

### No meaningful added cost

- WebSocket decoding and reducer transitions are negligible compared with model/TTS latency.
- The segment buffer is bounded by text already retained in the full assistant draft; it does not introduce a new asymptotic memory class.
- Segment activation uses the existing single timer scheduler / speech callback paths rather than polling.

## Domain model

### Agentd identity

Every main turn creates an opaque `turnToken`. Every visual segment has:

```ts
interface VisualNarrationSegmentIdentity {
  contextId: string;
  contextGeneration: number;
  turnToken: string;
  segmentId: string;
  ordinal: number;
}
```

Rules:

- `turnToken` changes on every new main turn/reset/abort boundary.
- `segmentId` is globally unique within process lifetime.
- `ordinal` starts at zero for each turn and increases in source order.
- App-side stale checks use the complete identity, not text or annotation ID.

### Prepared visual payload

```ts
type PreparedVisualPayload =
  | { kind: "point"; request: PickyPointerOverlayRequest }
  | { kind: "annotations"; request: PickyAnnotationOverlayRequest };
```

A prepared segment contains identity and one validated visual payload, but no finalized prose.

### Committed prose payload

```ts
interface VisualNarrationSegmentCommit {
  identity: VisualNarrationSegmentIdentity;
  text?: string; // absent for an empty segment
  originSource?: QuickReplyOriginSource;
  replyKind?: QuickReplyKind;
  sessionId?: string;
}
```

The text is immutable once committed.

### App state

Add a dedicated state cluster owned by `PickyInteractionReducer`:

```swift
struct PickyPreparedVisualNarrationSegment: Equatable, Codable {
    let identity: PickyVisualNarrationSegmentIdentity
    let visual: PickyPreparedVisualNarrationVisual
    var text: String?
    var precedingNarrationWeight: Double?
    var playbackMode: PickyVisualNarrationPlaybackMode?
    var speechID: UUID?
}

enum PickyVisualNarrationPlaybackMode: String, Codable {
    case incremental
    case finalReply
    case silent
}
```

State also needs:

- prepared/committed segment storage capped to the existing visual maximum;
- source-order queue;
- active segment identity;
- active visual narration text;
- current speaking visual segment identity;
- speechID → segment identity correlation;
- due segment identities for FIFO timer draining;
- turn identity used for stale rejection.

Do not overload `PickyPointerTarget.bubbleText`. That property belongs to the navigation-label path and would create two independent bubble writers.

## Wire protocol

Introduce three explicit events rather than giving existing overlay events hidden meanings.

### `mainVisualNarrationSegmentPrepared`

Emitted when a complete, valid RECT/LINE tag has been validated against captured context.

```json
{
  "type": "mainVisualNarrationSegmentPrepared",
  "identity": {
    "contextId": "context-1",
    "contextGeneration": 4,
    "turnToken": "turn-uuid",
    "segmentId": "segment-uuid",
    "ordinal": 0
  },
  "visual": {
    "kind": "annotations",
    "request": {
      "id": "annotations-uuid",
      "mode": "append",
      "annotations": [
        { "id": "dsl-1", "shape": "rect", "x": 100, "y": 200, "w": 300, "h": 80 }
      ],
      "contextId": "context-1",
      "contextGeneration": 4
    }
  }
}
```

### `mainVisualNarrationSegmentSentence`

Emitted exactly once for each completed sentence after the segment has been prepared. This is the progressive presentation unit; it carries the same full identity plus a zero-based sentence index.

```json
{
  "type": "mainVisualNarrationSegmentSentence",
  "identity": {
    "contextId": "context-1",
    "contextGeneration": 4,
    "turnToken": "turn-uuid",
    "segmentId": "segment-uuid",
    "ordinal": 0
  },
  "index": 0,
  "text": "첫 문장.",
  "originSource": "voice",
  "replyKind": "main"
}
```

### `mainVisualNarrationSegmentCommitted`

Emitted when the next visual opener is recognized or the turn ends. `sentenceCount` lets the app detect empty visual-only segments and incomplete delivery without reparsing prose.

```json
{
  "type": "mainVisualNarrationSegmentCommitted",
  "identity": {
    "contextId": "context-1",
    "contextGeneration": 4,
    "turnToken": "turn-uuid",
    "segmentId": "segment-uuid",
    "ordinal": 0
  },
  "text": "첫 문장. 둘째 문장.",
  "sentenceCount": 2,
  "originSource": "voice",
  "replyKind": "main"
}
```

### Existing events

- Explicit `pointerOverlayRequested` and `annotationOverlayRequested` remain unchanged for tool-driven, non-DSL requests.
- Tagless/orphan prose continues to use `mainNarrationChunk` and the existing sentence chunker.
- Visual-segment prose is not emitted a second time as `mainNarrationChunk`.
- A committed visual segment with non-empty text counts toward `mainNarrationChunkCount` / `didStreamNarration` semantics so an incremental provider does not repeat it in the final quick reply.
- A non-incremental provider displays sentence events progressively, then falls back to one final full `quickReply` synthesis.
- TTS-off mode still emits both ordinary and visual sentence events for cursor presentation, but never creates speech effects.

### Contract set that must change together

Per `docs/refactoring-principles.md`, update as one atomic protocol set:

- `agentd/src/protocol.ts`
- `agentd/src/protocol.test.ts`
- `agentd/src/server.ts`
- `contracts/protocol/main-visual-narration-segment-prepared.event.json` (new)
- `contracts/protocol/main-visual-narration-segment-sentence.event.json` (new)
- `contracts/protocol/main-visual-narration-segment-committed.event.json` (new)
- `Picky/PickyAgentProtocol.swift`
- `PickyTests/ProtocolContractTests.swift`

## Agentd design

### Parser output

Extend `AnnotationDslStreamItem` with a source-ordered visual boundary item:

```ts
| { kind: "visualBoundary"; verb: "RECT" | "LINE" }
```

For a complete tag in one delta, output order is:

```text
visualBoundary → tag
```

For a tag split across deltas:

1. Emit `visualBoundary` exactly once when the colon becomes known.
2. Retain the incomplete tag in parser pending state.
3. Later emit only `tag` when it closes and validates.
4. Do not emit a duplicate boundary when reprocessing the pending prefix.

Add explicit parser state such as `pendingVisualBoundaryEmitted`; do not infer duplication from raw string equality.

### Segment assembler

Create a pure domain policy, recommended path:

- New: `agentd/src/domain/visual-narration-segment.ts`
- New tests: `agentd/src/domain/visual-narration-segment.test.ts`

Responsibilities:

- accept ordered `text`, `visualBoundary`, and validated visual `tag` items;
- own the current prepared segment;
- append prose to the current segment and emit each completed sentence exactly once;
- flush the terminal sentence fragment and emit commit actions on boundaries/finalization;
- return orphan/tagless prose to the existing sentence chunker;
- preserve SCREEN transparency;
- preserve empty segments;
- prevent malformed visual prose from attaching to the previous segment;
- reset deterministically on turn reset/abort/error.

Keep parser grammar and segment ownership separate. The parser determines what token was seen; the segment assembler determines lifecycle transitions.

### Supervisor integration

Modify `agentd/src/session-supervisor.ts`:

- generate/reset `turnToken` and visual ordinal with the existing main turn lifecycle;
- route `streamItems` through the segment assembler;
- prepare visual requests using existing validation/build helpers without emitting legacy overlay events;
- emit `mainVisualNarrationSegmentPrepared` as soon as a tag is valid;
- emit `mainVisualNarrationSegmentSentence` for every completed visual sentence;
- emit `mainVisualNarrationSegmentCommitted` on early boundary/finalization;
- feed orphan prose to `NarrationSentenceChunker` unchanged;
- finalize the last segment before final `quickReply` / `mainTurnSettled`;
- count committed non-empty visual narration toward streamed narration bookkeeping;
- reset prepared/committed state on reset, abort, runtime failure, new main context, and completion.

Refactor request construction away from immediate emission if needed:

```text
build/validate request → return request
explicit tool path      → build + legacy emit
DSL segment path        → build + prepared event
```

Do not duplicate pointer/annotation validation logic.

### Server routing

Modify `agentd/src/server.ts` to broadcast all three new events. Preserve event order from `SessionSupervisor`.

Do not add independent asynchronous dispatch that could reorder prepared/sentence/committed events.

## Swift app design

### Protocol adapter

In `Picky/PickyAgentProtocol.swift`:

- decode the two new event types;
- model the identity and visual discriminated union;
- reuse existing `PickyPointerOverlayRequest` and `PickyAnnotationOverlayRequest` models;
- keep event fields strict enough to reject a prepared event with neither/both visual variants;
- keep the new commit `text` optional for empty segments.

### CompanionManager

In `Picky/CompanionManager.swift`:

#### Prepared event

- reject stale context/generation using `shouldApplyOverlay` before expensive work;
- RECT/LINE: resolve with `PickyAnnotationOverlayResolver` and existing palette logic;
- prepare/start annotation scene validation using the existing monitor path;
- submit one `.visualNarrationSegmentPrepared(...)` reducer event;
- do not set `latestAgentSessionSummary` to `Showing n screen annotations` for this path;
- do not expose bubble text yet.

#### Committed event

Resolve playback mode at the adapter boundary:

```text
TTS disabled / presentation-ineligible → silent
TTS enabled + provider supports incremental playback → incremental
TTS enabled + provider does not support incremental playback → finalReply
```

Submit `.visualNarrationSegmentCommitted(...)` to the reducer. The reducer, not the manager, owns ordering and activation decisions.

#### Effects

Continue using the existing effect runner:

- incremental segment speech uses the existing `.speak` effect;
- non-incremental final reply uses the existing final quick-reply TTS path;
- weighted activation uses the existing injected timer scheduler;
- cancellation uses existing speech/pointer/annotation cleanup effects.

No new actor or detached task is required. Keep orchestration on `@MainActor` per `docs/swift-concurrency.md`.

### Interaction events and state

Modify:

- `Picky/Interaction/PickyInteractionEvent.swift`
- `Picky/Interaction/PickyInteractionState.swift`
- `Picky/Interaction/PickyInteractionEffect.swift`
- `Picky/Interaction/PickyInteractionReducer.swift`
- `Picky/Interaction/PickyInteractionProjection.swift`

Add reducer events for:

- visual segment prepared;
- visual segment committed;
- visual segment activation due;
- speech started for a segment (reuse existing speech event plus speechID correlation where possible);
- stale/cancel cleanup through existing user-input and turn-reset events.

### Reducer state machine

```text
unknown
  ├─ prepared event ───────────────▶ prepared
  └─ commit-first race ────────────▶ commit buffered

prepared
  ├─ commit(empty) ────────────────▶ committed, no bubble
  ├─ commit(incremental) ──────────▶ queued speech
  ├─ commit(finalReply) ───────────▶ weighted pending activation
  └─ commit(silent) ───────────────▶ activate immediately

committed incremental
  └─ matching speechStarted ───────▶ active

committed finalReply
  └─ weighted activation due ──────▶ active

active
  ├─ next segment activates ───────▶ prior inactive, next active
  ├─ scene suspended ──────────────▶ visual/bubble projection hidden
  ├─ scene restored ───────────────▶ current active only; no replay
  ├─ final speech drain ───────────▶ bubble cleared; annotation policy continues
  └─ user input/clear/stale turn ──▶ removed
```

### Ordering rules

- Segment B may be prepared and committed while A is active.
- B must not mutate the active bubble until B activates.
- Timer callbacks may arrive out of order; drain activation in ordinal/FIFO order using the same pattern as `dueAgentAnnotationIDs`.
- Duplicate prepare/commit/activation is idempotent.
- Commit-before-prepare is buffered and joined by full identity.
- Stale context/generation/turnToken/segmentID events are ignored.
- A new user input clears prepared, committed, due, active, and speech-correlation state.

### Incremental TTS

For `PickySystemSpeechPlaybackProvider` and any future provider that returns `supportsIncrementalPlayback == true`:

- each completed visual sentence is one queued utterance;
- preserve segment identity plus sentence index on `PickyQueuedSpeechReply` and current speaking state/correlation;
- do not expose the next segment's prose merely because it was queued;
- when the provider accepts/starts the matching speechID, activate its visual and bubble in the same reducer transition;
- suppress the normal `.speaking` text projection until the matching visual segment activates, preventing prose from appearing before its visual;
- final `quickReply(didStreamNarration: true)` must not replay committed segment speech.

Tagless narration remains sentence-sized and follows the existing path.

### Non-incremental TTS

> Superseded by the approved sentence-progressive amendment above. The implemented contract is the following, not weighted playback timers.

Current non-incremental providers:

- OpenAI TTS
- Azure OpenAI TTS
- ElevenLabs
- Edge TTS
- `PickyFallbackSpeechPlaybackProvider` wrappers around those providers

These providers currently synthesize the final full reply once.

Implemented behavior:

- retain every visual segment and display completed sentences progressively during generation;
- do not enqueue one network TTS request per segment or sentence;
- terminal quick reply clears active visual sentence narration and starts one full utterance;
- the final full-reply bubble uses existing text-reply behavior, so audio never restarts while a stale final visual sentence remains active;
- final reply fallback remains available when no sentence was incrementally spoken.

### TTS disabled / silent presentation

- Visual segments still prepare and commit.
- No speech effect is created.
- Activate completed visual sentences immediately in source order, subject to scene validation.
- A terminal silent reply clears the active narration bubble and settles through the existing minimum-display text-reply path.
- Do not force the cursor into `.responding` solely to display a segment bubble if the existing owner/presentation policy would not show a cursor reply.
- Preserve the existing final text reply behavior.

### Annotation scene lifecycle

RECT/LINE segments must preserve the current scene policy:

- `validating`: geometry and active segment remain resident, projection hides annotation and segment bubble;
- `visible`: active visual and bubble may project;
- `suspended`: TTS continues, activation may advance internally, projection hides both;
- resume during TTS: show only the currently active segment; never replay elapsed segments;
- final TTS drain while suspended: existing permanent clear policy wins;
- final TTS drain while visible: annotations may remain with dismiss controls, but active narration bubble clears;
- post-TTS mismatch: existing permanent clear behavior wins;
- explicit dismiss: clears visual-segment state and monitor state together.


### Bubble projection

Add a single precedence policy in `PickyInteractionProjection`:

1. Active visual narration segment text, when its visual is currently projected.
2. Normal speaking/text reply.
3. Last display message fallback.

Additional rules:

- A committed but inactive segment cannot appear.
- A hidden/suspended annotation segment cannot appear.
- An empty segment cannot create `...` or synthetic text.
- Keep `PickyCursorResponseBubbleView` typography, wrapping, max-line, accessibility, and layout unchanged.

`CompanionResponseOverlayManager` currently has no producer. Do not add a second visual-segment state path there. If that panel is revived later, it must consume the same projection rather than independently infer segments.

## Failure handling and race safety

### New turn or reset

On main turn reset, abort, runtime error, new context, or app-side new user input:

- invalidate turnToken;
- clear parser pending boundary state;
- clear agentd segment assembler state;
- clear app prepared/committed/active maps;
- cancel segment activation timers;
- clear speechID correlations;
- preserve unrelated standalone pointer state only where current ownership rules already require it.

### Malformed/unclosed tag

- A recognized visual opener closes the previous segment.
- A malformed/unclosed tag never opens a new prepared segment.
- Existing dropped/healed diagnostics remain.
- No raw malformed DSL reaches visible prose.

### Prepared without commit

If a turn aborts after a visual is prepared but before commit:

- discard it without projection;
- stop any scene monitor created solely for that segment if no other segment owns it;
- do not synthesize a bubble or narration.

### Commit without prepare

Although WebSocket order should preserve prepared-before-commit, the reducer must tolerate commit-first delivery from journal replay/future adapters:

- buffer commit by full identity;
- join when prepare arrives;
- drop on stale turn or bounded-cap eviction.

### Speech failure

- If an incremental segment speech fails before activation, do not reveal its bubble as if it had spoken.
- Preserve minimum-display/failure cleanup contracts.
- Continue or clear pending visuals according to existing speech failure policy; make this explicit in reducer tests.
- A failed remote final-reply provider may fall back to macOS Speech through the existing wrapper without changing segment identities.

## Observability

Add structured, privacy-safe diagnostics. Never log prose, DSL coordinates in aggregate logs, URLs, or pixels.

Useful fields:

- context ID (existing redacted/local convention)
- context generation
- turn token suffix or hash
- segment ordinal
- visual kind
- text character count
- prepare-to-commit milliseconds
- commit-to-activate milliseconds
- playback mode
- activation outcome: active / stale / cancelled / hidden / empty

Suggested messages:

```text
visual narration segment prepared
visual narration segment committed
visual narration segment activated
visual narration segment ignored stale
visual narration segment cancelled
```

Do not add per-frame logs or a new polling worker.

## File-by-file change map

### Agentd domain

| File | Change |
|---|---|
| `agentd/src/domain/annotation-dsl.ts` | Emit early visual boundary items exactly once; keep SCREEN transparent. |
| `agentd/src/domain/annotation-dsl.test.ts` | Split-delta, healed opener, SCREEN, malformed barrier, duplicate-boundary tests. |
| `agentd/src/domain/visual-narration-segment.ts` | New pure segment assembler/policy. |
| `agentd/src/domain/visual-narration-segment.test.ts` | Grouping, final flush, empty segment, orphan prose, reset tests. |

### Agentd orchestration/protocol

| File | Change |
|---|---|
| `agentd/src/session-supervisor.ts` | Turn identity, prepare/commit lifecycle, final flush, streamed narration accounting. |
| `agentd/src/session-supervisor.test.ts` | Full ManualRuntime event-order and split-delta integration tests. |
| `agentd/src/protocol.ts` | Add prepared/committed event schemas and types. |
| `agentd/src/protocol.test.ts` | Parse valid/empty/stale-shape fixtures and reject invalid visual unions. |
| `agentd/src/server.ts` | Broadcast the two new supervisor events without reordering. |
| `agentd/src/server.test.ts` | Thin broadcast wiring test if existing server coverage does not already exercise generic events. |
| `contracts/protocol/main-visual-narration-segment-prepared.event.json` | New cross-language fixture. |
| `contracts/protocol/main-visual-narration-segment-committed.event.json` | New cross-language fixture. |

### Swift protocol/orchestration

| File | Change |
|---|---|
| `Picky/PickyAgentProtocol.swift` | Decode new event types, identity, and visual union. |
| `Picky/CompanionManager.swift` | Resolve prepared geometry, choose playback mode, submit reducer events, execute effects. |
| `Picky/PointerOverlay/PickyPointerOverlayResolver.swift` | Reuse as-is; change only if an adapter helper is required, not segment policy. |
| `Picky/PointerOverlay/PickyAnnotationOverlayResolver.swift` | Reuse as-is; keep palette/geometry behavior unchanged. |

### Swift interaction domain

| File | Change |
|---|---|
| `Picky/Interaction/PickyInteractionEvent.swift` | Add prepare/commit/activation events and Codable support. |
| `Picky/Interaction/PickyInteractionState.swift` | Add segment identities, prepared queue, active segment, speech correlation. |
| `Picky/Interaction/PickyInteractionEffect.swift` | Add/rename deterministic segment activation scheduling effect if needed. |
| `Picky/Interaction/PickyInteractionReducer.swift` | Own ordering, activation, scene gating, TTS-mode behavior, cleanup. |
| `Picky/Interaction/PickyInteractionProjection.swift` | Active visual segment bubble precedence and visibility. |
| `Picky/Interaction/PickyNarrationPaceModel.swift` | Reuse existing weighting; change only if tests demonstrate segment-level calibration needs adjustment. |

### Swift UI/tests/docs

| File | Change |
|---|---|
| `PickyTests/ProtocolContractTests.swift` | Decode both new fixtures. |
| `PickyTests/PickyInteractionReducerTests.swift` | Pure state/race/TTS mode tests. |
| `PickyTests/PickyCompanionManagerTests.swift` | Prepared/commit routing and fake provider orchestration. |
| `PickyTests/PickyAgentAnnotationOverlayTests.swift` | Projection visibility only if existing reducer coverage cannot prove it. |
| `docs/annotation-scene-profiling.md` | Add visual-segment activation and bubble synchronization manual checks after implementation. |
| `design/COMPONENTS.md` | Document response-bubble precedence for visual narration segments after implementation. |

## Test Plan Card

- **Change target:** agentd visual segmentation, app-daemon protocol, Swift interaction reducer, cursor response bubble projection.
- **User/system contract:** the active RECT/LINE annotation and response bubble always represent the same immutable prose segment.
- **Picky invariants:** reducer owns state; protocol evolves in both languages; stale/duplicate/race events cannot resurrect old UI; TTS continues during scene suspension; running app and real user environment are untouched by tests.
- **Selected layers:**
  - agentd pure unit for boundary/segment policy;
  - agentd SessionSupervisor integration for source order;
  - cross-language protocol fixtures;
  - Swift reducer unit for activation/race/scene lifecycle;
  - thin CompanionManager orchestration with fake TTS/timer/resolver inputs;
  - projection assertions instead of XCUI.
- **Excluded layers:**
  - no real ScreenCaptureKit/AX/audio/network;
  - no pixel snapshot or XCUI test because presentation style does not change;
  - no package/signing smoke because runtime packaging is unchanged.
- **Fake boundaries:** ManualRuntime, fake speech provider, injected interaction timer scheduler, fake annotation scene monitor.
- **Determinism:** fixed identity/UUID/date values; no arbitrary long sleeps; trigger callbacks and timer events directly.

### Required agentd cases

1. `[RECT:` boundary in one delta commits the previous segment before the new tag closes.
2. `[LI` + `NE:` across deltas emits one boundary only.
3. Case/whitespace-healed opener emits one boundary.
4. SCREEN does not split a segment.
5. RECT and LINE both split segments.
6. Unknown verbs do not split.
7. Malformed known visual opener splits the previous segment but opens no new segment.
8. Consecutive visual tags produce an empty first segment without borrowed prose.
9. Last segment commits before final quick reply/settled event.
10. Clean persisted assistant text remains identical and DSL-free.
11. Tagless prose retains sentence-level narration streaming.
12. Reset/abort drops prepared uncommitted segments.
13. Prepared and committed events carry stable identity/ordinal.
14. No segment prose is emitted twice as mainNarrationChunk.

### Required Swift reducer cases

1. Prepared alone changes no visible projection.
2. Commit alone changes no active bubble.
3. Segment A activation reveals A visual and A bubble atomically.
4. Segment B prepared/committed while A is active does not overwrite A.
5. Segment B activation replaces only the bubble and activates B visual in FIFO order.
6. Out-of-order activation timers preserve ordinal order.
7. Duplicate prepare/commit/activation is idempotent.
8. Stale context/generation/turnToken events are ignored.
9. Commit-before-prepare joins safely.
10. Empty segment reveals visual with no response bubble.
12. Incremental provider activates on matching speech start and queues each full segment once.
13. Non-incremental provider keeps one final full-reply utterance and uses weighted activation.
14. TTS-disabled path does not create speech effects.
15. Validating/suspended annotation scene hides active segment bubble.
16. Resume shows current segment only and never replays elapsed segments.
17. Final drain clears segment bubble while preserving visible dismissible annotations.
18. Final drain while suspended follows existing permanent-clear policy.
19. New user input clears pending/active segment and cancels owned timers/speech/pointer effects.
20. Standalone non-segment pointer/annotation behavior remains unchanged.

### Required CompanionManager cases

1. Prepared RECT/LINE resolves geometry and starts scene validation without projection.
3. Stale prepared event is rejected before resolver/monitor work.
4. Commit chooses incremental/finalReply/silent mode correctly.
5. Incremental segment uses fake provider once per segment.
6. Non-incremental provider receives only final full reply.
7. Generic `Showing n screen annotations` text cannot overwrite active segment bubble.
8. Explicit legacy overlay events still follow existing behavior.

## Implementation sequence

Follow TDD and commit each coherent contract separately. Do not mix unrelated refactors.

### Task 1: Characterize current source-order and bubble behavior

**Files:**

- Modify tests only: `agentd/src/session-supervisor.test.ts`
- Modify tests only: `PickyTests/PickyInteractionReducerTests.swift`

**Steps:**

1. Add characterization tests for current tag-before-prose event order and future-segment early arrival.
2. Assert current clean reply persistence and final non-duplication.
3. Run the two focused suites.
4. Do not change production code in this task.

**Commands:**

```bash
pnpm --dir agentd exec vitest run src/session-supervisor.test.ts
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  test -only-testing:PickyTests/PickyInteractionReducerTests
```

### Task 2: Add early visual boundary parsing

**Files:**

- Modify: `agentd/src/domain/annotation-dsl.ts`
- Modify: `agentd/src/domain/annotation-dsl.test.ts`

**Steps:**

1. Write failing tests for complete, split, healed, SCREEN, malformed, and duplicate boundary cases.
2. Extend stream items with `visualBoundary`.
3. Add pending-boundary ownership so a split tag emits once.
4. Preserve all existing cleanText/completedTags/healing behavior.
5. Run parser tests.

**Command:**

```bash
pnpm --dir agentd exec vitest run src/domain/annotation-dsl.test.ts
```

### Task 3: Extract the pure segment assembler

**Files:**

- Create: `agentd/src/domain/visual-narration-segment.ts`
- Create: `agentd/src/domain/visual-narration-segment.test.ts`

**Steps:**

1. Write failing grouping/finalization/reset tests.
2. Implement prepared/open/commit/orphan transitions as a pure policy.
3. Keep sentence chunking outside this policy.
4. Run the new unit suite.

**Command:**

```bash
pnpm --dir agentd exec vitest run src/domain/visual-narration-segment.test.ts
```

### Task 4: Integrate prepared/committed segments into SessionSupervisor

**Files:**

- Modify: `agentd/src/session-supervisor.ts`
- Modify: `agentd/src/session-supervisor.test.ts`

**Steps:**

1. Add failing ManualRuntime tests for prepared/commit order and final flush.
2. Generate turnToken/segmentID/ordinal deterministically through injectable/testable helpers where existing patterns allow.
3. Split request construction from legacy immediate emission without duplicating validation.
4. Route orphan prose through the existing sentence chunker.
5. Update streamed narration count and final reply behavior.
6. Reset all segment state on every main-turn terminal/reset path.
7. Run supervisor tests.

### Task 5: Add the cross-language protocol contract

**Files:**

- Modify: `agentd/src/protocol.ts`
- Modify: `agentd/src/protocol.test.ts`
- Modify: `agentd/src/server.ts`
- Add fixtures under `contracts/protocol/`
- Modify: `Picky/PickyAgentProtocol.swift`
- Modify: `PickyTests/ProtocolContractTests.swift`

**Steps:**

1. Add fixtures first and confirm Swift/TypeScript contract tests fail.
2. Add Zod and Swift models.
3. Add server broadcast wiring.
4. Verify empty commit and invalid prepared union behavior.
5. Run both contract suites.

**Commands:**

```bash
pnpm --dir agentd run test:contracts
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  test -only-testing:PickyTests/ProtocolContractTests
```

### Task 6: Add Swift segment state and reducer transitions

**Files:**

- Modify: `Picky/Interaction/PickyInteractionEvent.swift`
- Modify: `Picky/Interaction/PickyInteractionState.swift`
- Modify: `Picky/Interaction/PickyInteractionEffect.swift`
- Modify: `Picky/Interaction/PickyInteractionReducer.swift`
- Modify: `PickyTests/PickyInteractionReducerTests.swift`

**Steps:**

1. Add failing tests for prepare/commit/activate and B-before-A-finish race.
2. Add identity, bounded storage, active state, and speech correlation.
3. Implement incremental/finalReply/silent paths.
4. Reuse FIFO due-drain policy from annotation reveal.
5. Add stale/duplicate/commit-first/new-input cleanup tests.
6. Add scene suspend/resume/final-drain tests.
7. Run reducer tests.

### Task 7: Wire CompanionManager and effect execution

**Files:**

- Modify: `Picky/CompanionManager.swift`
- Modify: `PickyTests/PickyCompanionManagerTests.swift`

**Steps:**

1. Add fake-provider tests for mode selection and exact utterance count.
2. Resolve prepared RECT/LINE without visual activation.
3. Submit reducer events with full identities.
4. Route speak/timer/pointer/annotation effects through existing runners.
5. Remove generic summary overwrite only for segment-prepared events.
6. Verify legacy overlay request paths remain unchanged.

### Task 8: Project the active segment through the existing bubble

**Files:**

- Modify: `Picky/Interaction/PickyInteractionProjection.swift`
- Modify: `Picky/Overlay/BlueCursorView.swift`
- Modify tests near reducer/projection; avoid XCUI.

**Steps:**

1. Add failing projection tests for inactive/active/suspended/empty states.
2. Give active visual narration text explicit precedence.
3. Suppress premature queued `.speaking` text until activation.
5. Keep existing layout/style/accessibility unchanged.

### Task 9: Update product and profiling documentation

**Files:**

- Modify: `design/COMPONENTS.md`
- Modify: `docs/annotation-scene-profiling.md`
- Modify this document's status and resolved implementation notes.

**Steps:**

1. Document the final event/state names actually implemented.
2. Add manual scenarios for incremental/non-incremental TTS and scene suspension.
3. Record measured latency before/after; do not claim improvement without data.

### Task 10: Full validation and focused commits

**Validation order:**

```bash
# Agentd focused
pnpm --dir agentd exec vitest run \
  src/domain/annotation-dsl.test.ts \
  src/domain/visual-narration-segment.test.ts \
  src/session-supervisor.test.ts \
  src/protocol.test.ts

# Agentd contract/type/build/full
pnpm --dir agentd run test:contracts
pnpm --dir agentd run typecheck
pnpm --dir agentd run build
pnpm --dir agentd run test:serial

# Swift focused
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  test \
  -only-testing:PickyTests/ProtocolContractTests \
  -only-testing:PickyTests/PickyInteractionReducerTests \
  -only-testing:PickyTests/PickyCompanionManagerTests

# Swift full — serial per repository guidance
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO test

# Build and diff hygiene
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" build
git diff --check
```

Use conventional commits and never amend. Suggested commit boundaries:

1. `test: characterize visual narration ordering`
2. `feat: add visual narration segment protocol`
3. `feat: synchronize visual narration bubbles`
4. `docs: document visual narration segments`

## Manual acceptance scenarios

Do not automate these against the user's running app. After the user explicitly relaunches a validated build:

### Incremental macOS Speech

1. Submit a voice or Quick Input request that yields three visual segments.
2. Confirm the first visual and only its full prose bubble appear together.
3. Confirm the second segment can already be prepared without changing the first bubble.
4. Confirm the bubble switches only when the second visual activates.
5. Confirm final quick reply is not spoken twice.

### Multi-sentence segment

1. Produce one RECT followed by two sentences and then LINE.
2. Confirm the RECT bubble contains both sentences from the start.
3. Confirm no intermediate sentence-only bubble appears.

### Split opener

1. Use a deterministic agentd test/log to observe a next opener split across deltas.
2. Confirm commit occurs at the colon, not at `[LI` and not after the full LINE arguments.

### Non-incremental remote provider

1. Select OpenAI/Azure/ElevenLabs/Edge TTS.
2. Confirm only one final TTS request/utterance occurs.
3. Confirm weighted visual changes and bubble changes remain paired.

### Scene suspension

1. Begin a multi-segment annotated narration.
2. Change app/window or scroll so the annotation scene suspends.
3. Confirm TTS continues and both annotation and visual segment bubble hide.
4. Return before TTS ends.
5. Confirm only the current segment appears; elapsed segment bubbles do not replay.

### Final drain

1. Let narration finish while the original scene remains valid.
2. Confirm the narration bubble disappears.
3. Confirm annotations remain with the explicit close control.
4. Confirm later mismatch permanently clears them as currently specified.

## Rollout and rollback

### Rollout

- Land parser/segment tests before app behavior.
- Land protocol changes atomically across TypeScript, fixtures, and Swift.
- Keep legacy explicit overlay events intact.
- Measure prepare-to-commit and commit-to-activate latency in Debug before tuning.
- Do not change pacing constants in the same commit unless measurements show a regression.

### Rollback

The implementation must remain easy to disable:

- Agentd can route DSL visuals through legacy overlay events and sentence narration if the new segment feature is disabled.
- App must continue decoding and handling legacy events.
- Removing new segment event emission should restore old behavior without protocol downgrade or state migration.
- Persisted interaction journals must decode missing new segment fields as empty/default state.

A temporary feature flag is optional during development, but do not add a permanent user setting unless rollout evidence requires it.

## Definition of done

Implementation is complete only when all are true:

- [x] Agentd owns visual segment boundaries; Swift performs no DSL/text inference.
- [x] RECT/LINE are boundaries; SCREEN is transparent.
- [x] Early opener detection commits at the colon exactly once across split deltas.
- [x] Prepared geometry is invisible and can start validation early.
- [x] Canonical segment prose is immutable after commit; sentence progress is emitted exactly once before commit.
- [x] Visual and bubble activate in the same reducer transition.
- [x] An incremental future segment cannot overwrite the active bubble before matching speech start.
- [x] Multi-sentence ordinary and visual prose accumulates one completed sentence at a time.
- [x] Incremental TTS queues one utterance per visual sentence and does not repeat the final reply.
- [x] Non-incremental TTS keeps one final full-reply synthesis and clears stale visual sentence activation first.
- [x] TTS-disabled replies stream completed sentences and settle through the existing text-reply lifecycle without speech.
- [x] Full turn identity/tombstones reject delayed stale segments after user input or reset.
- [x] Empty visual-only segments reveal without borrowing prose or leaking an invisible scene monitor.
- [x] Scene validating/suspended/resume/final-drain policies remain correct.
- [x] Explicit legacy pointer/annotation tools remain unchanged.
- [x] Protocol schemas, fixtures, Swift decoding, and both contract suites agree.
- [x] Focused and full agentd/Swift suites pass.
- [x] macOS build and `git diff --check` pass.
- [x] Running Picky app was not restarted by automation.
- [ ] Manual runtime acceptance and Debug profiling remain to be performed after an explicit app relaunch.

## Reference map

- `AGENTS.md`
- `docs/refactoring-principles.md`
- `docs/swift-concurrency.md`
- `docs/annotation-scene-profiling.md`
- `design/COMPONENTS.md`
- `agentd/src/prompt-builder.ts`
- `agentd/src/domain/annotation-dsl.ts`
- `agentd/src/domain/narration-sentence-chunker.ts`
- `agentd/src/session-supervisor.ts`
- `agentd/src/protocol.ts`
- `Picky/PickyAgentProtocol.swift`
- `Picky/CompanionManager.swift`
- `Picky/Interaction/PickyInteractionReducer.swift`
- `Picky/Interaction/PickyInteractionProjection.swift`
- `Picky/Overlay/BlueCursorView.swift`
- `agentd/src/session-supervisor.test.ts`
- `PickyTests/PickyInteractionReducerTests.swift`
- `PickyTests/PickyCompanionManagerTests.swift`
- `PickyTests/ProtocolContractTests.swift`
