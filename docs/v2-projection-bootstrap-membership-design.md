# V2 authoritative bootstrap membership / deletion design

## Decision

Add a v2-only, unicast `sessionProjectionBootstrapComplete` frame containing the daemon epoch and the complete set of session IDs represented by a **successfully completed socket bootstrap**. Picky prunes only after this frame arrives, never while individual bootstrap snapshots stream.

Do **not** add a deletion tombstone in this change. The currently evidenced stale-card path is daemon restart/reconnect: retention purge runs during `SessionSupervisor.load()` before a v2 socket registers, while normal HUD/CLI deletion already performs local cleanup. A tombstone is the right follow-up only if a supported producer can delete a session while a v2 client remains connected.

This is a high-blast-radius protocol/state change (estimated 9/10): shared wire contract and daemon broadcaster (fan-in 4/4), stateful Swift application/registry cleanup (fan-out 3/3), and substantial recent churn in each affected module (2/3). Require a protocol-focused review before implementation.

## 1. Problem and verified current behavior

### Current behavior

1. A v2 registration sends one `sessionProjectionSnapshot` per entry returned by `supervisor.list()`, under a per-session barrier. It buffers live frames, flushes them after the snapshot loop, then removes bootstrap state. There is no completion/index-membership frame (`agentd/src/application/session-projection-v2-broadcaster.ts:68-106`). The broadcaster explicitly skips an ID deleted between `list()` and its barrier (`:83-87`).
2. The protocol contains projection transaction and snapshot event schemas only (`agentd/src/protocol.ts:661-680`) and the event union includes only those two v2 event types (`:767-769`). The projection mutation union has no deletion variant (`agentd/src/protocol.ts:390-407`).
3. `deleteSession` in the server comments that v2 has no deletion mutation, then broadcasts a legacy `sessionSnapshot` (`agentd/src/server.ts:623-627`). `sendSessionSnapshot` returns immediately for any dialect other than v1 (`:674-680`), so v2 sockets receive no deletion signal.
4. On connection, Swift leaves its session storage intact and sends `listSessions` (`Picky/PickySessionViewModel.swift:1726-1738`). `listSessions` calls `sendSessionSnapshot` on the daemon (`agentd/src/server.ts:389-392`), which is intentionally a no-op for v2 as above. Swift instead receives incremental projection snapshots through `PickySessionRecoveryCoordinator` (`Picky/PickySessionViewModel.swift:1756-1761` and `Picky/Sessions/PickySessionRecoveryCoordinator.swift:55-71`), which applies each snapshot independently. No existing event replaces the complete membership.
5. The daemon purges retained archived sessions in `load()` after hydration (`agentd/src/session-supervisor.ts:356-359`), and `purgeStaleArchivedSessions` deletes them from the in-memory map and persisted store (`:361-385`). This is the concrete restart/reconnect stale-card path.
6. Existing v1 complete snapshots perform exactly the required class of reconciliation: archive IDs are intersected with the complete snapshot universe (`Picky/PickySessionViewModel.swift:1861-1872`), and per-session caches are pruned from the same known-ID set (`:2301-2327`). V2 currently cannot establish that universe.

### User-visible failure

1. Picky has session `A` and `A` is present in persisted `manuallyArchivedSessionIDs`.
2. `picky-agentd` restarts. During `load()`, retention/daemon cleanup removes `A`.
3. Picky reconnects. The v2 bootstrap has no snapshot for `A`, but does not say that the index is complete.
4. Swift preserves `A`'s registry/card and persisted archive intent. The stale archived row, associated dock/layout references, and per-session cache state remain until a full app restart or some unrelated local cleanup.

Normal Settings deletion is not this failure: `deleteArchivedSession` calls `finalizeDeletedArchivedSession` locally (`Picky/PickySessionViewModel.swift:1639-1660`). The current server-side purge is startup-only, not a repeating live timer (`agentd/src/session-supervisor.ts:356-385`).

## 2. Options

| Option | Reconnect correctness | Live-deletion latency | Compatibility and failed bootstrap | Implementation size |
|---|---|---|---|---|
| A. Bootstrap index-complete membership frame | Solves the evidenced restart/reconnect gap. The app prunes only after authoritative completion. | No new live deletion behavior. Existing HUD/CLI local cleanup remains responsible. | Additive v2 event. Old app decodes unknown events as `.unknown` and ignores them (`Picky/PickyAgentProtocol.swift:430-433`); new app connected to old daemon never receives completion and retains current conservative behavior. On bootstrap failure, daemon closes before completion, so Swift must not prune. | Small-medium: protocol/fixtures, broadcaster state/order, Swift event/application cleanup/tests. |
| B. Per-session deletion tombstone only | Insufficient. A reconnect after the daemon already purged a session has no tombstone to replay, so stale local membership persists. Requires a deletion journal/replay or an authoritative bootstrap anyway. | Immediate for supported live deletion producers. | Additive event is safe to ignore, but ordering needs a global membership sequence or explicit incarnation/generation to prevent a delayed tombstone deleting a recreated ID. A failed bootstrap still has no authoritative absence proof. | Medium-large: supervisor deletion event, broadcaster, global ordering model, Swift deletion reducer, replay/reconnect semantics. |
| C. Index-complete frame plus deletion tombstone | Correct for reconnect and provides immediate external/live deletion updates. | Immediate. | Same failed-bootstrap guard as A, plus B's ordering/incarnation requirements. | Largest. Useful only if a supported external live deleter is a product requirement. |

### Why Option A is sufficient now

The scope is specifically server disappearance across daemon restart/reconnect. The only verified automatic deletion producer, retention purge, happens before clients register. The normal UI/CLI deletion path already invokes the app's local cleanup. Adding a durable tombstone/replay stream now would create a second membership ordering system without an evidenced producer that needs it.

### Important bootstrap concurrency constraint

A completion marker must not be emitted after only the initial `supervisor.list()` loop. The existing broadcaster queues live `sessionProjectionSnapshot` and transaction frames while registering (`agentd/src/application/session-projection-v2-broadcaster.ts:149-160`). A session created during registration may therefore be absent from the initial list but present in the queued frames. The completion marker must be emitted **after** all queued frames are flushed and must derive membership from the successfully sent bootstrap/queued snapshot IDs, filtered against `supervisor.get(id)` immediately before the marker. This keeps a deletion that happened during bootstrap out of membership and includes a creation observed during bootstrap.

This is still not a general live-deletion protocol. A deletion after the marker has no v2 frame and is intentionally out of scope for Option A.

## 3. Recommended contract and algorithm

### Contract sketch

Add an event, not a mutation. Membership is a collection-level fact, while `PickySessionProjectionMutation` is a mutation of an existing session's durable fields.

```json
{
  "id": "event-projection-bootstrap-complete-001",
  "protocolVersion": "2026-08-25",
  "timestamp": "2026-08-25T00:00:00.000Z",
  "type": "sessionProjectionBootstrapComplete",
  "epoch": "epoch-001",
  "sessionIds": ["session-001", "session-002"]
}
```

Schema shape in `agentd/src/protocol.ts`:

```ts
export const PickySessionProjectionBootstrapCompleteEventSchema = EventBaseSchema.extend({
  type: z.literal("sessionProjectionBootstrapComplete"),
  epoch: z.string().min(1),
  sessionIds: z.array(z.string().min(1)).superRefine(rejectDuplicates),
});
```

Add `contracts/protocol/session-projection-bootstrap-complete.event.json`, add the schema to `EventEnvelopeVariantSchema`, and add matching Swift decoding:

```swift
case sessionProjectionBootstrapComplete(PickySessionProjectionBootstrapComplete)

struct PickySessionProjectionBootstrapComplete: Decodable, Equatable {
    let epoch: String
    let sessionIds: [String]
}
```

`sessionIds` is an unordered membership set on the wire. It must contain unique nonempty IDs. It does not prescribe HUD ordering, which remains the app's manual-order/creation-time policy.

### Daemon emission and ordering

Affected daemon files: `agentd/src/protocol.ts`, `agentd/src/application/session-projection-v2-broadcaster.ts`, `agentd/src/server.ts` only insofar as the broadcaster payload type changes, and one contract fixture.

1. Extend the broadcaster payload union with the completion event. Keep it v2-only and unicast to the registering socket, never broadcast to already-live v2 sockets.
2. Extend `V2BootstrapState` with `observedSessionIDs: Set<string>` and `epoch: string?`.
3. Obtain the daemon's current projection epoch explicitly even for an empty bootstrap, for example by adding `projectionEpoch(): string` to `SessionProjectionV2Supervisor`. Do not infer it from the first snapshot because an empty index has none. The actual epoch is currently one immutable `randomUUID()` per `SessionSupervisor` process (`agentd/src/session-supervisor.ts:141-145`).
4. During each successful initial barrier snapshot, require its epoch to equal the bootstrap epoch, send the snapshot, record its session ID/revision, and add the ID to `observedSessionIDs`. An epoch mismatch is a failed bootstrap: close the socket without a completion event.
5. Flush queued frames in their existing order. Whenever a queued `sessionProjectionSnapshot` is sent, add its `sessionId` to `observedSessionIDs`; transactions do not create membership. Preserve the current discard rule for transactions already represented by a newer snapshot (`session-projection-v2-broadcaster.ts:92-97`).
6. Immediately after the queue flush, synchronously form `sessionIds` from `observedSessionIDs.filter(id => supervisor.get(id) !== undefined)`, verify the epoch has not changed, and send `sessionProjectionBootstrapComplete`. Delete bootstrap state only after this send.
7. If any snapshot/barrier/frame construction fails, preserve current behavior: close the socket and discard queued frames (`:99-105`). Never send the completion event for a partial bootstrap.
8. After completion, future projection frames use the existing direct send path. Option A deliberately does not emit a frame for a subsequent deletion.

Ordering invariant for a successful registration:

```text
all initial bootstrap snapshots
  -> all queued frames accumulated while bootstrapping
  -> sessionProjectionBootstrapComplete(epoch, sessionIds)
  -> subsequent direct live frames
```

The implementation must maintain this invariant for an empty bootstrap too: it emits exactly one completion event with `sessionIds: []`. WebSocket ordering plus the broadcaster's synchronous send path makes the completion a safe cutover marker. The event must not be put before queued frames, otherwise Swift could permanently prune a session created while registration was in progress.

### Swift application algorithm

Affected Swift files: `Picky/PickyAgentProtocol.swift`, `Picky/PickySessionViewModel.swift`, `Picky/PickySessionViewModel+SessionProjectionV2.swift`, likely `Picky/Sessions/PickySessionRecoveryCoordinator.swift`, and protocol/application/storage tests.

1. Add the event case and decoding. Route it from `PickySessionListViewModel.apply(_:)` to a v2-only `applySessionProjectionBootstrapComplete(_:)` method.
2. Track a bootstrap-completion expectation per connection in a small coordinator/policy object. Reset it on `.connected`. Bootstrap snapshots seen before the completion establish the expected epoch. Accept completion only when:
   - the connection is awaiting a completion frame,
   - all observed bootstrap snapshots have the completion's epoch (or the index is empty), and
   - the frame has not already completed that connection/epoch.

   A completion that fails these checks is ignored and logged, not used to prune. This is defensive against future transport/router changes that could surface stale frames. The current transport's one socket message order is still the primary ordering guarantee.
3. On accepted completion, calculate `removedIDs = knownRegistryIDs - Set(event.sessionIds)`. `knownRegistryIDs` must include both active and archived registry membership, not only current `sessions`; it must not include non-daemon onboarding/demo data unless that data is explicitly marked as projection-owned.
4. Cancel pending archive commits for every removed ID, remove the ID from both archive-store sets, and cancel/clear the recovery coordinator state for that session. Clearing recovery state is necessary so a recreated ID cannot replay buffered transactions from its old incarnation.
5. Remove each ID from projection storage/registry. The existing registry's `replaceMembership` removes child stores outside membership (`Picky/Sessions/Projection/PickySessionRegistry.swift:31-49`), and `PickyRegistrySessionProjectionStorage.removeSession` already publishes compatible façade steps (`Picky/Sessions/PickyRegistrySessionProjectionStorage.swift:55-67`). Prefer adding a batch `removeSessions(ids:)` storage operation so completion emits one coherent publication rather than N UI transitions.
6. Prune all per-session state using the final known set. The existing v1 `pruneSlashCommandCache` is the baseline (`Picky/PickySessionViewModel.swift:2301-2327`), but the authoritative-v2 helper must also cover the deletion-only cleanup in `finalizeDeletedArchivedSession` (`:1646-1688`):
   - `manuallyArchivedSessionIDs` and `archivedSessionIDs`
   - `unreadSessionIDs`, `pendingDoneFlashSessionIDs`, `deliveredNotificationKeys`
   - thinking/todo/subagent expansion maps
   - slash-command cache and composer draft/attachment state
   - incremental cursors, pending terminal metadata, released-child IDs, archive commit tasks
   - diff stores and `visibleSessionDiffSessionIDs`
   - inline/shell terminal sessions, command chains/handles, and visible terminal attachments
   - pending dock-group assignments for absent IDs.
7. Reconcile in this order after storage removal: prune caches -> `applyManualOrder()` (which invokes `reconcileDockLayout()` at `Picky/PickySessionViewModel.swift:2477-2487`) -> selection/voice-follow-up/screen-context synchronization. This makes dock groups lose absent members only after the registry/card set is final and prevents a selection or context target from pointing at a removed card.
8. Mark the bootstrap complete and unblock the initial-snapshot watchdog/loading state even for `sessionIds: []`. Individual snapshots currently unblock it (`Picky/PickySessionViewModel+SessionProjectionV2.swift:59-64`), so the empty case otherwise remains indefinitely loading.

### Failure and edge cases

| Case | Required behavior |
|---|---|
| Bootstrap fails or socket disconnects midway | Daemon closes/disconnects without completion. Swift retains all local membership and cache state. Reconnect starts a fresh bootstrap. |
| Empty daemon index | Daemon sends completion with the current epoch and `[]`. Swift accepts it and removes all projection-owned stale sessions, archive IDs, dock members, and state. |
| Epoch mismatch during bootstrap | Daemon treats it as an incomplete index and closes without completion. Swift never prunes from a mismatched frame. Current epoch is process-wide immutable, but make the guard contractual. |
| Duplicate/delayed completion | Swift accepts once per connection/epoch; later duplicates are no-ops. |
| Session deleted between `list()` and its per-session barrier | Existing broadcaster skips its snapshot; it is absent from the final filtered ID set and is pruned at completion. |
| Session created during bootstrap | Its queued snapshot is flushed before completion and recorded in the ID set. It survives completion. |
| Session deleted after completion | Option A does not update it remotely. Existing local HUD/CLI cleanup applies; add Option C before supporting an external live deleter. |
| ID deleted then recreated | Completion removes the old registry/cursor state first. A later creation snapshot materializes a fresh store. Do not reuse buffered recovery state for the ID. UUID-like session IDs make reuse unlikely, but this remains an explicit invariant. |
| Recovery request for a deleted ID | The current server recovery barrier can fail because the session no longer exists. With Option A, a successful reconnect completion cleans it. This design does not change in-place recovery semantics. |

## 4. Test plan

### Agentd contract and broadcaster tests

1. **Schema/fixture**: `agentd/src/protocol.test.ts` parses the new event, rejects duplicate/empty IDs, and `contracts/protocol/session-projection-bootstrap-complete.event.json` is covered by the fixture protocol tests.
2. **Successful nonempty bootstrap**: extend `agentd/src/application/session-projection-v2-broadcaster.test.ts` to assert snapshots, queued live frames, then exactly one completion with the correct epoch and IDs.
3. **Empty bootstrap**: assert exactly one completion with `sessionIds: []` and a nonempty current epoch.
4. **Deleted during bootstrap**: preserve the existing regression but now assert the deleted ID is absent from completion, the subsequent created snapshot is present, and completion is emitted before subsequent direct live frames.
5. **Creation during bootstrap**: defer a barrier, emit a creation snapshot, release the barrier, and assert the completion includes both the original and created IDs after the queued snapshot.
6. **Failure/disconnect**: extend existing partial-bootstrap and unregister tests to assert no completion frame escapes.
7. **Server integration**: extend the v2 registration test in `agentd/src/server.test.ts` to check one unicast completion, correct ordering, no legacy `sessionSnapshot`, and that the current v1 delete bootstrap tests remain v1-only.
8. **Runtime deletion path**: construct an expired archived session, `load()` a new `SessionSupervisor`, register v2, and assert the completion excludes the purged ID. This is the actual production path, not merely a mocked `deleteSession` test.

### Swift protocol/application tests

1. **Contract fixture**: `PickyTests/ProtocolContractTests.swift` decodes the new fixture into the named event case; malformed duplicate IDs become `.unknown`/fail the strict payload decoder according to existing convention.
2. **Reconnect regression**: in `PickyTests/PickySessionProjectionV2ApplicationTests.swift`, seed active and archived cards plus stale `manuallyArchivedSessionIDs`, simulate reconnect snapshots excluding one stale ID, then completion. Assert active/archived façades, registry store existence, archive sets, dock layout, unread/done flash, and selection/context target are all pruned only after completion.
3. **No premature prune**: assert a stale local card remains after the first of several bootstrap snapshots and disappears only at completion.
4. **Empty index**: existing sessions and archive IDs are removed by an accepted empty completion; loading state becomes false.
5. **Failed/no completion**: simulate snapshots then disconnect/no marker; assert local membership and local archive intent remain. This protects the current conservative failure behavior.
6. **Created while bootstrapping**: apply a queued creation snapshot before completion and assert the marker includes/preserves it.
7. **Epoch/stale-marker guard**: a marker whose epoch differs from the observed bootstrap epoch, and a duplicate accepted marker, must not incorrectly prune.
8. **Recreated ID/recovery cleanup**: create buffered recovery state for `A`, prune `A` by completion, then deliver a new bootstrap snapshot for `A`; assert no old buffered transaction applies.
9. **Storage batch behavior**: add focused `PickyRegistrySessionProjectionStorageTests` coverage that removing multiple IDs removes registry stores and emits a single final active/archived projection suitable for dock reconciliation.

## 5. Migration, rollout, and blast radius

### Compatibility

- **Old app + new daemon**: the old app may still advertise `sessionProjectionV2`, receive the additive unknown event, and ignore it. Its behavior remains unchanged, including the stale-card limitation. `PickyEvent` intentionally maps unrecognized event types to `.unknown` (`Picky/PickyAgentProtocol.swift:430-433`).
- **New app + old daemon**: old daemon emits no completion. New app must retain existing local membership and never prune merely because a timeout elapsed. This is safe degradation, though it cannot repair stale cards until both sides are updated.
- **v1 clients**: no behavior or event changes. `sessionProjectionBootstrapComplete` must be generated only for a v2 registration.
- **Protocol version**: follow the repository's existing release policy for whether this additive same-version event is released under `2026-08-25` or triggers a coordinated version bump. The current version gate rejects unequal protocol versions (`agentd/src/application/protocol-version-guard.ts:1-7`), so a version bump is a distribution decision, not a transparent mixed-version migration. The event itself is backward-safe because Swift has an explicit unknown-event fallback.

### Expected implementation blast radius

- TypeScript: protocol schema/event union, fixture, broadcaster payload/bootstrap state, supervisor epoch accessor, broadcaster/server/protocol tests.
- Swift: protocol event decoding, ViewModel routing and one authoritative reconciliation helper, recovery coordinator cleanup API, registry storage batch removal, protocol/application/registry tests.
- No runtime, persistence-format, HUD rendering, signing, or app-launch changes are required.

### Follow-up trigger

Implement Option C only if any of the following becomes supported: a server retention job that runs after connection, a remote/admin/second-client deletion producer, or a product requirement that a deletion initiated outside this ViewModel disappear immediately. That follow-up needs a distinct global membership ordering/incarnation design, not an unversioned per-session tombstone.
