# Per-Pickle daemon topology

_Last updated: 2026-09-06_

Picky.app talks to more than one `picky-agentd` process. This document is the
reference for who hosts what, how connections are keyed, and which rules decide
session ownership when several daemons report the same session id. The rules
themselves live in `Picky/Sessions/Projection/PickyProjectionOwnershipLedger.swift`
and are unit-tested in `PickyTests/PickyProjectionOwnershipLedgerTests.swift`.

## 1. Processes

```text
Picky.app
  ├─ primary daemon   127.0.0.1:17631   PICKY_AGENTD_MODE=primary (default)
  │     hosts: main Picky agent, CLI/external Pickles, handoff/pinned Pickles,
  │            settings/dock-group/push-to-talk bridges, Pi OAuth, package ops
  └─ child daemon ×N  random port       PICKY_AGENTD_MODE=child
        hosts: exactly one manual Pickle, bound to that Pickle's workspace cwd
```

| Env var | Primary | Child |
|---|---|---|
| `PICKY_AGENTD_TOKEN` | shared bearer token | same token |
| `PICKY_AGENTD_PORT` | fixed (17631) | omitted; child binds a random port |
| `PICKY_AGENTD_PARENT_PID` | app pid, daemon exits with the app | same |
| `PICKY_AGENTD_SESSION_ID` | – | required; the only session id the child may create |
| `PICKY_AGENTD_SESSION_CWD` | – | required; initial default cwd |
| `PICKY_AGENTD_PRIMARY_URL` | – | primary websocket URL for completion forwarding |
| `PICKY_APP_SUPPORT_DIR` | app support root | same root; sessions share one store |

`agentd/src/bootstrap.ts` validates the mode. In child mode the session id
factory is single-use: the first `create` returns the configured id and any
second create throws, so a child can never grow a second session.

## 2. Lifecycle

1. The HUD asks `PickySessionListViewModel` to create a manual Pickle. The view
   model calls `PickyManualPickleChildSpawning.spawnManualPickleChild` on the
   router.
2. `PickyAgentDaemonPool.spawnChild` launches `picky-agentd` in child mode and
   waits for the `picky-agentd listening on 127.0.0.1:<port>` stdout line. The
   pool owns the process; it does not retry.
3. `PickyAgentClientRouter.spawnChildClient` builds a websocket client for the
   endpoint, registers app capabilities (including `sessionProjectionV2`), and
   starts forwarding events under the owner key `child:<sessionId>`.
4. Commands addressed to that session id are routed to the child; everything
   else goes to the primary (`connectedClient(for:)`).
5. `releaseChild` tears the websocket down, terminates the process through the
   pool, and marks the id retired. A retired id can be respawned with the same
   id (same cwd) after a HUD restart; ownership returns to the child only once
   the pool has actually recreated it.

Pickle completion notifications never originate in the app. A child daemon
forwards its completion to the primary (`forwardPickleCompletionToPrimary`),
and the primary delivers it to the main agent through the app-owned coordinator
so the user's Main Picky / macOS destination is honored.

## 3. Session projection ownership

Every connection (primary or child) delivers its own v2 projection stream:
`sessionProjectionSnapshot` per session during bootstrap,
`sessionProjectionBootstrapComplete` with the full membership it observed, then
live `sessionProjectionTransaction` frames. Because all daemons share one
session store, the primary can also list sessions a child currently hosts.
The ledger decides how those overlapping views combine:

- **Owner assignment.** A session id is owned by the first connection whose
  current bootstrap snapshot reports it. A later snapshot from a different
  connection is forwarded for rendering but never transfers ownership.
- **Generation and correlation.** `registerAppCapabilities` starts a bootstrap
  generation per owner key. A completion is accepted only if it matches the
  current generation and bootstrap id, was not already accepted, and its epoch
  equals the epoch the snapshots of that bootstrap carried. A bootstrap that
  observes two epochs is poisoned until the next registration.
- **Pruning scope.** An accepted completion removes only records owned by that
  connection that the completed index no longer lists. Primary cannot prune a
  live child's record and a child cannot prune primary records.
- **Booting children.** A child completion becomes destructive only after that
  connection generation has produced the snapshot for its own session and the
  router still holds a live, non-retired client for it. An empty index that
  arrives before the first scoped snapshot is consumed for correlation only.
- **Released children.** `releaseChild` transfers ownership to primary but
  remembers the primary epoch at release time. A primary completion that omits
  the released id is not authoritative until its epoch differs from the release
  epoch, which proves a daemon restart rehydrated the shared store rather than a
  same-process socket reconnect.
- **Disconnect.** Dropping all sockets clears per-connection correlation and the
  known primary epoch but keeps session ownership, so a reconnect cannot
  reassign records to the wrong owner.

The five failed approaches that led to these rules are recorded in
`docs/known-issues/cross-daemon-session-ownership.md`.

## 4. Where to look

| Concern | File |
|---|---|
| Child process lifecycle | `Picky/PickyAgentDaemonPool.swift` |
| Command routing, child client cache, retirement | `Picky/PickyAgentClientRouter.swift` |
| Ownership and completion rules (pure) | `Picky/Sessions/Projection/PickyProjectionOwnershipLedger.swift` |
| Mode/env validation, single-use session id | `agentd/src/bootstrap.ts` |
| Projection bootstrap on the daemon | `agentd/src/application/session-projection-v2-broadcaster.ts` |
| Completion forwarding | `agentd/src/application/pickle-completion-coordinator.ts` |
