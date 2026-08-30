# Resolved issue: cross-daemon session ownership ghosts (BUG-3-1)

Status: resolved by Session Projection v2. Production advertises
`supportsSessionProjectionV2`, and owner-scoped bootstrap completion is the
authoritative membership/deletion path. BUG-3-2 router-cache eviction is also
fixed.

The legacy v1 `sessionSnapshot` fallback still uses whole-list replacement, so
this document remains useful as historical context for old-dialect debugging.
It is not an open production redesign item.

## Historical symptom

`PickySessionViewModel.applySessionSnapshot` treats a v1 `sessionSnapshot` as
the authoritative global session list and replaces both `sessions` and
`archivedSessions` wholesale. In the per-Pickle architecture each daemon (the
primary plus one child daemon per Pickle) could emit a snapshot built only from
its own `supervisor.list()`. A child daemon's post-delete empty snapshot, or a
primary reconnect, could therefore remove unrelated Pickle cards from the HUD.

## Historical root cause

Session ownership authority was conflated with WebSocket transport state. Early
fix attempts tried to forward a merged global v1 snapshot, but reconnect and
child-release races made that cache another mutable authority owner.

## Shipped resolution

Projection v2 replaced global full-snapshot deletion authority with an
owner-scoped protocol:

- each routed connection keeps its source owner, generation, and daemon epoch;
- `sessionProjectionBootstrapComplete` carries the complete membership observed
  by one successful bootstrap for one socket owner;
- `PickyAgentClientRouter` accepts a completion only when its owner, generation,
  epoch, and bootstrap correlation are current;
- pruning removes only records owned by that connection, so a child cannot
  remove primary records and primary cannot remove a live child's records;
- explicit child release transfers ownership conservatively to primary and
  prevents stale child completions from pruning;
- router regression tests cover owner isolation, reconnect, and released-child
  reconciliation.

Implementation entry points:

- `agentd/src/application/session-projection-v2-broadcaster.ts`
- `agentd/src/protocol.ts` (`sessionProjectionBootstrapComplete`)
- `Picky/PickyAgentClientRouter.swift`
- `PickyTests/PickyAgentClientRouterTests.swift`

## Historical failed approaches

Incremental v1 router-cache patches each closed one race but exposed another:

1. A child's empty snapshot wiped other daemons' cards.
2. Primary reconnect reclaimed a live child's session ID.
3. Child permanent teardown left ghost cache entries.
4. Transient child reconnect transferred authority too early.
5. A generation-token refactor briefly allowed two async iterators to consume
   the same client stream, so a retired iterator could swallow current events.

Projection v2 avoids making a merged v1 cache authoritative and keeps one
consumer per routed client stream.
