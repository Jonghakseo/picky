# Known issue: cross-daemon session ownership ghosts (BUG-3-1)

Status: open. Router-cache eviction (BUG-3-2) is fixed and committed; the HUD
full-snapshot wipe (BUG-3-1) is only partially mitigated and is intentionally
**not** patched incrementally because the underlying ownership model needs a
focused redesign.

## Symptom

`PickySessionViewModel.applySessionSnapshot` treats a `sessionSnapshot` as the
authoritative global session list and replaces both `sessions` and
`archivedSessions` wholesale. In the per-Pickle architecture each daemon (the
primary plus one child daemon per Pickle) emits a snapshot built only from its
own `supervisor.list()`. A child daemon's post-delete empty snapshot, or a
primary reconnect, can therefore remove unrelated Pickle cards from the HUD.

## Root cause

Session ownership authority is conflated with websocket-transport state. Any
correct fix must forward a **merged global snapshot** to the view model
(each daemon's current sessions unioned, deduped by id) instead of a single
daemon's partial snapshot.

## Why it is not patched yet

Incremental patches on `PickyAgentClientRouter` were attempted and each closed
one race but exposed another:

1. Core: a child's empty snapshot wiped other daemons' cards.
2. Primary reconnect (`SessionStore.loadAll()` includes nested child sessions)
   reclaimed a live child's session id, blocking the child's later deletion.
3. Child permanent teardown (pool-exit / explicit release) left ghost cache
   entries.
4. Transient child ws disconnect/reconnect transferred authority to primary.

A root-cause refactor that tracked authority by stable daemon identity plus a
"forwarder generation token" introduced a worse regression: after
disconnect/reconnect two async iterators consumed the same client event stream
concurrently, so a retired iterator could swallow a legitimate current-transport
event (snapshots or protocol requests silently lost). That refactor was reverted.

## Required fix (for a dedicated follow-up)

- Track session authority by stable daemon identity (primary, or a specific
  child slot/session key), independent of transient websocket connection state.
- Clear/transfer a child's authority to primary **only** on explicit release or
  pool-exit, never on a transient ws disconnect.
- A primary snapshot must never steal an id currently authoritative to a
  non-released child.
- Forward a merged global snapshot to the view model; keep the bridge cache
  (BUG-3-2) consistent with it.
- Guarantee exactly **one** iterator consumes each client event stream across
  transport reconnects (retain the forwarder across reconnects, or fully retire
  the old iterator before starting its replacement) so no legitimate event is
  dropped.
- Regression tests must be non-vacuous: subscribe before emitting the primary
  snapshot and assert the merged snapshot is actually observed before the child
  reconnect/empty-snapshot step.
