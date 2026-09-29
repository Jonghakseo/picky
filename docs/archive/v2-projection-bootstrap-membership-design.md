# V2 authoritative bootstrap membership / deletion design

Status: implemented end to end (2026-08-30). The design-time “current behavior” and future-tense implementation sections below are retained as historical rationale; the shipped contract lives in `agentd/src/protocol.ts`, `agentd/src/application/session-projection-v2-broadcaster.ts`, `Picky/PickyAgentClientRouter.swift`, and their tests.

## Decision

Projection v2 uses a unicast `sessionProjectionBootstrapComplete` event. It marks the
complete membership for one **successful bootstrap of one socket owner**, not
for the app globally. It contains the daemon epoch, the registering
`registerAppCapabilities` command ID as `bootstrapId`, and the complete
membership set observed before live delivery begins.

Picky removes cards only after accepting that event at the router boundary. It
prunes only records owned by the emitting connection. In particular, a child
daemon completion must never remove a primary-owned card, and a primary
completion must never remove a child-owned card.

Do **not** add a deletion tombstone in this change. The evidenced stale-card
path is daemon restart/reconnect: `SessionSupervisor.load()` purges retained
archived sessions before a v2 socket registers. Normal HUD/CLI deletion
already performs local cleanup. A tombstone is a follow-up only if a supported
producer can delete a session while a v2 client remains connected.

This was a high-blast-radius protocol/state change because it changed a shared
wire contract, the daemon bootstrap barrier, router ownership propagation, and
registry-backed Swift cleanup. The shipped implementation includes protocol,
broadcaster, router, and registry cleanup coverage.

## 1. Historical problem and verified pre-implementation behavior

1. A v2 registration sends one `sessionProjectionSnapshot` per entry returned
   by `supervisor.list()` under a per-session barrier, buffers live frames,
   flushes them, then removes bootstrap state. It has no index-complete event
   (`agentd/src/application/session-projection-v2-broadcaster.ts:68-106`). A
   session deleted between `list()` and its barrier is deliberately skipped
   (`:83-87`).
2. The projection protocol currently has only transaction and snapshot event
   schemas (`agentd/src/protocol.ts:672-691`). Its mutation union has no
   deletion variant (`:390-407`).
3. `SessionSupervisor.load()` purges retained archived sessions after hydration
   (`agentd/src/session-supervisor.ts:356-385`). This is the concrete
   restart/reconnect stale-card path.
4. A v2 socket intentionally does not receive legacy `sessionSnapshot`
   deletion/update frames (`agentd/src/server.ts:669-680` and `:1024-1026`).
   The app therefore has incremental projections but no complete membership
   universe.
5. Picky registers `sessionProjectionV2` on the primary connection and every
   forwarded child connection. The router forwards their events through one
   source-free public stream (`Picky/PickyAgentClientRouter.swift:851-947`),
   while a child daemon is scoped to exactly one session
   (`agentd/src/bootstrap.ts:119-128,176`). Therefore the original global
   calculation `knownRegistryIDs - completion.sessionIds` is unsafe.
6. The existing v1 router cache already scopes a complete `sessionSnapshot` by
   `ownerKey`: it removes only entries whose stored owner equals the emitting
   owner (`Picky/PickyAgentClientRouter.swift:1020-1043`). V2 membership must
   mirror that boundary.
7. The existing registry `replaceMembership` removes only stores outside the
   supplied membership while retaining stores that survive
   (`Picky/Sessions/Projection/PickySessionRegistry.swift:31-49`). In contrast,
   `PickyRegistrySessionProjectionStorage.removeSession` calls `install`, which
   re-replaces every remaining card through the façade
   (`Picky/Sessions/PickyRegistrySessionProjectionStorage.swift:55-67,172-179`).

### User-visible failure

1. Picky has session `A`, including persisted `manuallyArchivedSessionIDs`.
2. `picky-agentd` restarts and `load()` purges `A` by retention policy.
3. Picky reconnects. V2 sends no snapshot for `A`, but has no way to declare
   the index complete.
4. Picky preserves `A`'s card, archive intent, dock/layout references, and
   per-session state until an unrelated local cleanup or app restart.

Normal Settings deletion is not this failure: it invokes
`finalizeDeletedArchivedSession` locally. The automatic purge above is
startup-only, not a repeating live deletion timer.

## 2. Contract

### Event shape

Add an event, not a mutation. Membership is a collection fact, while
`PickySessionProjectionMutation` modifies one session's durable fields.

```json
{
  "id": "event-projection-bootstrap-complete-001",
  "protocolVersion": "2026-08-25",
  "timestamp": "2026-08-25T00:00:00.000Z",
  "type": "sessionProjectionBootstrapComplete",
  "epoch": "epoch-001",
  "bootstrapId": "register-capabilities-command-id",
  "sessionIds": ["session-001", "session-002"]
}
```

In `agentd/src/protocol.ts`, add the event to `EventEnvelopeVariantSchema`:

```ts
export const PickySessionProjectionBootstrapCompleteEventSchema = EventBaseSchema.extend({
  type: z.literal("sessionProjectionBootstrapComplete"),
  epoch: z.string().min(1),
  bootstrapId: z.string().min(1),
  sessionIds: z.array(z.string().min(1)).superRefine(rejectDuplicates),
});
```

`sessionIds` is an unordered membership set. It must contain unique nonempty
IDs and does not prescribe HUD order.

Swift adds a matching dormant v2 event case and strict decoder. Empty `epoch`,
empty `bootstrapId`, an empty session ID, or duplicate IDs makes the payload
invalid and therefore `.unknown`, matching the current
`PickySessionProjectionProtocol` invalid-v2-payload convention
(`Picky/PickySessionProjectionProtocol.swift:283-299`).

### Correlation and router delivery contract

`bootstrapId` is exactly the `PickyCommandEnvelope.id` of the
`registerAppCapabilities` command that caused this bootstrap. The router must
construct that envelope before sending it and record its ID with the source
connection. It must not synthesize a second correlation ID.

The public router stream currently loses source identity. Before it broadcasts
a v2 projection event, the router must carry internal routing metadata to the
v2 application boundary:

```text
(ownerKey, connectionGeneration, event)
```

This may be an internal routed-event wrapper or a dedicated router callback;
it must not infer owner from `sessionId` in the ViewModel. The primary owner
key is `primary`; a child owner key is `child:<sessionId>`, consistent with
`childEventKey(_:)`. `connectionGeneration` changes on every raw socket
connect for that owner. The primary needs an equivalent generation counter;
children already have lifecycle generations, but the implementation must also
advance the connection generation for a reconnect of the same child client.

On every raw connect, the router records the new generation and the newly sent
registration command ID. On raw disconnect, it invalidates the expectation for
that owner/generation. A completion is eligible only if all of the following
hold:

1. its routed owner and connection generation are still current;
2. its `bootstrapId` equals the registration ID recorded for that exact
   owner/generation;
3. its nonempty `epoch` equals every bootstrap snapshot epoch observed for that
   owner/generation, or there were no snapshots; and
4. `(ownerKey, connectionGeneration, bootstrapId, epoch)` has not already been
   accepted.

The router logs and discards a mismatched, stale, disconnected, or duplicate
completion. It marks a valid completion accepted before forwarding it for
application, so re-entrancy cannot apply removal twice. Expectations and
accepted keys are reset/invalidated on raw connect and disconnect, not merely
at the ViewModel lifecycle boundary.

## 3. Owner-scoped authority

The completion's set is authoritative only for current membership mapped to
its owner. The router maintains projection ownership while it routes bootstrap
snapshots, analogous to its v1 `sessionOwnerKeys` cache. An accepted completion
calculates:

```text
removedIDs = projectionOwnedRegistryIDs(ownerKey) - Set(completion.sessionIds)
```

It must never calculate against all registry IDs. Local-only onboarding/demo
cards have no projection owner and are excluded.

### Ownership lifecycle rules

| Owner state | Membership authority and completion handling |
|---|---|
| Primary daemon | A current, correlated primary completion is authoritative for all and only registry IDs recorded as primary-owned. It can prune stale primary records, including an empty primary index. It immediately unblocks primary initial loading. |
| Active child | Once the child has produced a projection snapshot for its configured session in its current generation, a current, correlated child completion is authoritative only for IDs recorded with that child owner. The child process is single-session scoped, so this normally means one ID. It can never remove a primary or another child's ID. |
| Booting child | `spawnChildClient` marks the child booting before the child has produced a session (`Picky/PickyAgentClientRouter.swift:515-531`). A booting child's empty completion is consumed for correlation/duplicate protection but has **no destructive authority**. It does not remove an earlier card and does not unblock primary loading. The first routed projection snapshot for the configured child session marks that generation session-producing; subsequent bootstrap/reconnect completions use the active-child rule. This prevents the normal pre-creation empty child index from deleting unrelated or previous state. |
| Retired/released child | `releaseChild` stops forwarding the child event key before disconnecting and terminates the daemon (`Picky/PickyAgentClientRouter.swift:601-614`). Its generation is invalid. No completion from it is forwarded or accepted, and it cannot prune. The router transfers that session's projection ownership to `primary` at release and records the current primary daemon epoch. The primary only discovers child records from the shared store during daemon startup, so a same-epoch primary socket reconnect cannot prune the retained record when it is absent. A primary completion from a different epoch proves a restarted supervisor rehydrated the store and is authoritative; inclusion always confirms survival. If no release-time primary epoch is known, exclusion remains conservatively non-authoritative until an explicit ownership proof. |
| Primary epoch change | A daemon restart creates a new primary connection generation and normally a new immutable supervisor epoch. Old expectations/acceptances are invalidated on disconnect. Snapshots establish the new expected epoch; only the completion correlated to the new primary registration can reconcile prior primary-owned membership. A mismatched epoch is discarded, never used to prune. |

A child may not claim or migrate primary ownership merely because it lists the
same ID. The router assigns ownership only from frames carried by the current
source connection. If a session is intentionally moved between daemon owners,
that operation needs an explicit owner-transfer rule and is out of this
change's scope.

This resolves the first blocking question: ownership is per emitting daemon
connection, never app-global, and lifecycle states determine whether a
completion has destructive authority.

## 4. Daemon bootstrap algorithm and bounded queue

Affected daemon files are `agentd/src/protocol.ts`,
`agentd/src/application/session-projection-v2-broadcaster.ts`,
`agentd/src/session-supervisor.ts`, and `agentd/src/server.ts`.

1. `registerAppCapabilities` passes `cmd.id` as `bootstrapId` to the v2
   broadcaster. Only a transition from negotiating to v2 starts this process;
   v1 behavior is unchanged.
2. Expose `projectionEpoch(): string` on `SessionProjectionV2Supervisor` so an
   empty bootstrap has a current epoch. Do not infer it from the first
   snapshot. `SessionSupervisor` already owns one immutable random UUID epoch
   per process.
3. Create state with `bootstrapId`, `epoch = supervisor.projectionEpoch()`,
   `observedSessionIDs`, `snapshotRevisions`, a queued payload list, queued
   byte count, and an `active`/`failed` phase.
4. For every successful initial barrier snapshot, require its epoch to equal
   the state epoch, send it, record its revision, and add its ID to
   `observedSessionIDs`. If the listed ID disappears before the barrier,
   preserve the current skip behavior. Any other barrier, construction, or
   epoch error fails the bootstrap, closes the socket, clears queued payloads,
   and emits no completion.
5. Flush queued frames in order. Add a queued snapshot's ID to
   `observedSessionIDs`; transactions do not create membership. Preserve the
   existing discard of transactions already represented by a newer snapshot.
   Reject a queued projection whose epoch differs from bootstrap epoch.
6. Immediately after that flush, synchronously compute
   `sessionIds = observedSessionIDs.filter(id => supervisor.get(id) !==
   undefined)`, recheck the epoch, and unicast exactly one completion with the
   stored `bootstrapId`. Only after `send(completion)` succeeds may the state
   become live/remove its active bootstrap entry.
7. Never broadcast completion to already-live v2 sockets. A failed or partial
   bootstrap, disconnect, or unregister emits no completion.

The resulting successful ordering invariant, including an empty list, is:

```text
all initial bootstrap snapshots
  -> all queued live frames accumulated while bootstrapping
  -> sessionProjectionBootstrapComplete(epoch, bootstrapId, sessionIds)
  -> subsequent direct live frames
```

This includes a session created during registration via its queued snapshot and
excludes a session deleted before the final `supervisor.get` filter. It remains
an index cutover, not a general live-deletion protocol.

### Queue bounds

The current `queued.push(payload)` is unbounded
(`session-projection-v2-broadcaster.ts:155-159`). Bound both dimensions:

- `MAX_BOOTSTRAP_QUEUE_FRAMES = 1_024`;
- `MAX_BOOTSTRAP_QUEUE_BYTES = APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT` (the existing
  8 MiB frame budget minus envelope reserve).

For every queued frame, calculate its serialized event size with the existing
`eventPayloadByteLength` helper from
`app-session-snapshot-policy.ts:10-12,130-138`. Enqueue only if both the count
and `queuedBytes + payloadBytes` remain within the limits. This accounts for
serialized rather than object-memory size and keeps the aggregate under the
same budget policy as an app event frame.

On overflow, atomically change the bootstrap state to `failed`, clear queued
payloads and byte count, close the socket, and emit no completion. Retain that
failed sentinel in the socket state map until `unregister(socket)`, rather than
deleting it in a `finally` block. While the sentinel exists, broadcast paths
must discard frames for that socket, not take the normal direct-send path
before transport close is observed. The same no-direct-send rule applies after
an epoch/bootstrap failure until closure is observed.

## 5. Swift application and destructive cleanup

### Accepted completion application

The router, not the ViewModel, enforces source/correlation ownership. It passes
only an accepted routed completion with its `ownerKey` to the application
helper. The helper obtains `removedIDs` using the owner-scoped formula above;
it does not reset or rehydrate surviving stores.

Add `removeSessions(ids:)` to
`PickyRegistrySessionProjectionStorage`. It must:

1. read current active/archived membership;
2. filter removed IDs from both arrays;
3. call `registry.replaceMembership(active:archived:)` directly, without
   `install` or replacing surviving cards; and
4. materialize and publish one final active/archived projection.

This preserves surviving child-store identity and produces one membership
publication, suitable for one dock reconciliation rather than N lossy UI
transitions.

For every removed ID, the authoritative completion helper must clear all
session-owned state before/with batch membership removal:

- cancel archive commit tasks and call `clearPendingArchiveIntent(sessionID:)`,
  which removes both pending archive correlation maps
  (`Picky/PickySessionViewModel.swift:1572-1578`);
- remove it from `archivedSessionIDs`, `manuallyArchivedSessionIDs`, released
  child IDs, unread IDs, done-flash IDs, and delivered notification keys;
- remove every recovery coordinator state/buffer/correlated request for that
  ID through a dedicated per-session removal API. This prevents a recreated ID
  from replaying old buffered transactions;
- clear thinking, todo, and subagent expansion maps; slash-command cache;
  incremental cursors; pending terminal metadata; diff stores and visible-diff
  IDs; dock pending assignments; and all terminal command-chain/handle state;
- clear composer text, attachments, and pending composer request **for each
  removed ID**. The generic `composerDraftController.prune(knownSessionIDs:)`
  intentionally preserves persisted drafts when the known set is empty
  (`Picky/Sessions/PickySessionComposerDraftController.swift:142-149`), so the
  completion path needs `clearDraft(sessionID:)` or a separate explicitly
  authoritative prune API;
- close inline and shell terminal sessions and attachments. Extend
  `PickyTerminalOverlayPresenting` with an explicit close operation and close
  each removed session's stored overlay handle, then remove the handle mapping;
- set `openSessionRequest` to `nil` when it targets a removed ID, and clear
  selected/hovered/active voice-follow-up and screen-context targets when they
  target a removed ID.

After all removals, use this order:

```text
batch registry membership removal
  -> prune remaining caches from final known membership
  -> applyManualOrder()
  -> selection, voice-follow-up, active-voice, and screen-context synchronization
```

This ensures dock groups are reconciled after final membership and no target
points at a removed card. The implementation should use the ViewModel's dock
mutation batching so the operation is observable as one coherent transition.

### Preserve independent reset semantics

Completion is only an absence/removal operation. It must never reset a
surviving store's logs, tools, artifacts, or presentation. Existing
`logsSet`/`toolsSet`/`artifactsSet` transaction mutations already own reset
semantics (`agentd/src/protocol.ts:397-403`). Pi-session-path snapshot/patch
handling and terminal-sync banner clearing are also separate snapshot/reset
semantics. Do not fold either behavior into membership reconciliation.

### Loading watchdog

An accepted **primary** completion disarms the initial-snapshot watchdog and
sets `isLoadingInitialSessionSnapshot` false, including for `sessionIds: []`.
A child completion never does this. No completion, including an old-daemon
connection, retains current conservative behavior: the existing watchdog still
unblocks loading after roughly four seconds
(`Picky/PickySessionViewModel.swift:397-407`), rather than leaving it loading
indefinitely or treating elapsed time as authority to prune.

## 6. Failure and edge cases

| Case | Required behavior |
|---|---|
| Bootstrap fails, queue overflows, or socket disconnects midway | Close/disconnect without completion. Retain local membership and cache state. The failed sentinel blocks direct-send leakage until unregister. |
| Empty primary index | A valid primary completion with `[]` removes all primary-owned stale sessions and unblocks loading. |
| Empty booting-child index | The completion is correlated/consumed but non-destructive. It does not remove a prior card or unblock primary loading. |
| Empty active-child index | A valid active-child completion can remove only that child's owned IDs. |
| Epoch/bootstrapId/generation mismatch | Router discards it, logs the reason, and never prunes. Daemon treats its own bootstrap epoch mismatch as failed and closes without completion. |
| Duplicate/delayed completion | Router accepts once per `(ownerKey, connectionGeneration, bootstrapId, epoch)` and drops later copies. |
| Child completion alongside primary cards | It cannot remove primary or sibling-child membership. The reciprocal rule also applies to primary completion. |
| Session deleted between `list()` and barrier | It has no snapshot, is absent from final filtered membership, and is pruned only if it is owned by that completing owner. |
| Session created during bootstrap | Its queued snapshot precedes completion, records ownership, and its ID is included in completion membership. |
| Session deleted after completion | This option deliberately emits no v2 deletion frame. Existing local HUD/CLI cleanup applies. |
| ID deleted then recreated | Per-session recovery/cursor/draft/terminal state is removed with the old membership. A later snapshot creates fresh state. |

## 7. Test plan

### Agentd contract, broadcaster, and server

1. Add `contracts/protocol/session-projection-bootstrap-complete.event.json`.
   `agentd/src/protocol.test.ts` accepts a valid event and rejects empty epoch,
   missing/empty `bootstrapId`, empty IDs, and duplicate IDs.
2. In `session-projection-v2-broadcaster.test.ts`, assert successful nonempty
   ordering: initial snapshots, queued frames, exactly one completion with the
   current epoch, registration command ID, and final IDs, then direct frames.
3. Assert an empty bootstrap still emits one completion with `[]` and a
   nonempty epoch.
4. Cover deletion between `list()` and barrier, creation during bootstrap,
   final `supervisor.get` filtering, epoch mismatch, partial failure,
   disconnect, and no completion after any failure.
5. Cover both queue limits. Assert overflow clears queued payloads, closes,
   produces no completion, and a later broadcast cannot direct-send before
   `unregister` removes the failed sentinel.
6. In `server.test.ts`, verify v2 registration passes the command ID and
   receives one unicast completion in order with no legacy `sessionSnapshot`;
   v1 receives neither v2 frames nor completion.
7. Build an expired archived session, `load()` a new supervisor, register v2,
   and assert the completion excludes the purged ID. This validates the real
   stale-card producer.

### Swift protocol, router, storage, and application

1. `ProtocolContractTests` decodes the fixture to the new event case. Invalid
   strict payloads become `.unknown` according to the dormant-v2 convention.
2. Router tests cover primary and child registration IDs, connection-generation
   reset on raw connect/disconnect, epoch mismatch, bootstrapId mismatch,
   duplicate completion, and stale delayed completion.
3. Router/application tests assert a child completion never prunes primary or
   sibling-child sessions, and a primary completion never prunes child sessions.
   Cover booting-child empty completion as non-destructive, active child
   reconciliation, and retired/released child event rejection.
4. Reconnect regression: seed active and archived primary cards plus stale
   `manuallyArchivedSessionIDs`; snapshots alone preserve them; accepted primary
   completion removes only the stale primary IDs.
5. Empty primary completion removes owned stale cards and archive IDs and
   unblocks loading. Failed/no completion preserves all local intent; the
   watchdog alone does not prune. Child completion never unblocks primary
   loading.
6. Cover created-during-bootstrap ownership, recreated-ID recovery isolation,
   and that surviving stores retain identity through a batch prune.
7. Add focused storage/registry coverage for multiple removed IDs: one final
   publication, removed stores absent, surviving stores untouched.
8. Add cleanup coverage for pending archive correlations, recovery state,
   composer drafts/attachments including authoritative-empty removal,
   terminal overlays/handles, and `openSessionRequest`.
9. Regression-test that completion does not clear surviving logs/tools/artifacts
   or alter independent Pi-path/banner reset behavior.

## 8. Migration, compatibility, and rollout

### Compatibility

- **Old app + new daemon:** the event is additive under the existing
  `2026-08-25` protocol version. An old app maps unrecognized event types to
  `.unknown` (`Picky/PickyAgentProtocol.swift:382-388`) and retains its current
  stale-card limitation.
- **New app + old daemon:** the old daemon emits no completion. The new app
  retains local membership and does not prune after timeout. This is safe
  degradation, though it cannot repair stale cards until both sides update.
- **v1 clients:** no behavior or event changes. Completion is generated only
  for v2 registration.
- **No protocol-version bump:** `assertProtocolVersion` rejects any unequal
  client/server version (`agentd/src/application/protocol-version-guard.ts:1-6`).
  A bump would break both mixed directions before unknown-event compatibility
  could help, so this additive event stays at `2026-08-25`.

This resolves the second blocking question: the feature is additive and must
not bump the protocol version.

### Expected implementation blast radius

- TypeScript: schema/event union/fixture, supervisor epoch accessor,
  broadcaster bootstrap state and bounds, server registration command ID, and
  protocol/broadcaster/server tests.
- Swift: event decoding, routed source metadata and completion guard, ownership
  map, authoritative cleanup helper, recovery removal API, registry storage
  batch operation, explicit terminal-overlay close API, and protocol/router/
  application/storage tests.
- No persistence-format, HUD rendering, signing, or app-launch change is
  required.

### Follow-up trigger

Implement a tombstone/replay design only if a server retention job runs after
connection, a remote/admin/second-client deletion producer is supported, or a
product requirement demands immediate external live deletion. That follow-up
needs explicit ordering and incarnation semantics, not an unversioned
per-session tombstone.
