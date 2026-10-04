# Projection conformance scenarios

Language-neutral scenarios that pin how a Picky client folds a v2 projection
stream into session state. Each file is one scenario: an ordered list of wire
events plus the state they must produce.

The normative behaviour is the Swift storage reducer
(`Picky/Sessions/PickyRegistrySessionProjectionStorage+V2.swift` and the child
stores under `Picky/Sessions/Projection/`). `agentd/src/domain/session-projection-reducer.ts`
is the TypeScript reference implementation of the same rules, so a web client
never becomes a third reading of the protocol. Both must pass every scenario
here; the TS runner is `agentd/src/domain/session-projection-reducer.test.ts`,
and the Swift conformance test lands in a following step.

## File format

```json
{
  "name": "scenario-id",
  "description": "What regression this scenario catches.",
  "events": [ { "type": "sessionProjectionSnapshot", "...": "wire envelope" } ],
  "expect": {
    "sessionPresent": true,
    "signals": { "localPresentationResets": 1 },
    "queueModes": { "steeringMode": "all", "followUpMode": "one-at-a-time" },
    "sections": {
      "logs": { "state": "loaded", "value": ["one", "two"] },
      "tools": { "state": "unavailable" }
    }
  }
}
```

- `events` use the same envelopes as `contracts/protocol/session-projection-*.event.json`,
  so both runners decode them with the production protocol types. Only
  `sessionProjectionSnapshot` and `sessionProjectionTransaction` appear here;
  bootstrap completion is client membership policy, not reducer input.
- `expect` is checked as a deep partial. An object compares only the keys the
  scenario lists, arrays must match in length and order, and everything else is
  left unchecked so an added protocol field does not break every scenario.
- `null` in `expect` means "no value". JSON cannot distinguish absent from
  `undefined`, and Swift optionals collapse the same way.
- `expect.sessionPresent: false` means the stream produced no hydrated session
  at all, which is how a transaction for an unknown session must end.

## Sections, and why `unavailable` is not `[]`

State is compared per section, not as one flattened session record. A section is
`unavailable` until a snapshot or mutation supplies it, which is a different
claim from `loaded` with an empty value:

| state | meaning | client should render |
| --- | --- | --- |
| `{"state":"unavailable"}` | the daemon never sent this section | nothing, or a loading affordance |
| `{"state":"loaded","value":[]}` | the daemon says the section is empty | "no tools", "no artifacts" |

Flattening to a session card erases that difference, so a bounded snapshot that
omitted `tools` would be indistinguishable from a session that ran no tools.
Scenarios therefore assert sections directly.

Section names: `meta`, `logs`, `tools`, `todo`, `subagentRuns`, `asyncTaskDetail`,
`asyncControl`, `artifacts`, `changedFiles`, `messages`, `messageJournalAvailable`,
`queue`, `activity`, `extensionUiRequest`.

Two pairings come from the Swift store layout and are easy to get wrong:

- `artifacts` and `changedFiles` share one owner. Omitting either in a snapshot
  leaves both unavailable, and writing either one loads the other.
- `queueModes` is scalar metadata that lives outside the `queue` section, so the
  delivery modes survive an omitted queue collection.

## Signals

`signals` are routing facts a client needs that are not stored projection data:

- `localPresentationResets`: times the stream told the client to drop
  locally-owned presentation (the `/new` replacement pattern, or a snapshot that
  swapped the Pi session file). In Swift this is `clearLocallyOwnedProjectionPresentation()`,
  so a Swift runner can assert it by setting `isWritingReply` before the stream
  and checking it was cleared.
- `progressOnlyTransactions`: transactions made only of `asyncTaskDetailSet` /
  `asyncControlSet`, which Swift applies through `applyAsyncTaskDetailTransaction`
  without rebuilding the conversation card.
- `ignoredTransactions` / `ignoredSnapshots`: events dropped whole, because the
  session had no loaded metadata or the snapshot's `projection.id` disagreed
  with its `sessionId`.

## Out of scope

- **Ordering.** The reducer ignores `baseRevision` and replaces `revision`
  outright. Gap detection belongs to `PickySessionRevisionCursor`.
- **Unknown mutation types.** They are rejected at decode time, and the whole
  transaction is discarded; `PickyTests/ProtocolContractTests.swift` covers that.
- **Client policy.** Archive intent, selection, notifications, slash-command
  cache invalidation and daemon ownership/epoch rules sit above the reducer.
- **Derived presentation.** Log preview, the optimistic request timestamp and
  the Pi path parsed out of log lines have no projection owner. Scenarios keep
  Pi session paths in metadata so the two reducers stay comparable.

## Known gaps in the server diff (not pinned here)

`buildSessionProjectionMutations` in `agentd/src/domain/terminal-session-finalization.ts`
plans the mutations these scenarios consume. Two asymmetries exist today and are
documented rather than asserted, because the daemon does not currently produce
them:

- Inserting a message, tool or artifact in the *middle* of a collection, or
  reordering one without changing content, produces upserts (or nothing at all),
  and both reducers append new ids to the end. Order then differs from the
  daemon's. Every current producer appends chronologically.
- `asyncTasks` set with `completionTickets` absent diffs to `asyncTaskDetailSet: null`,
  which clears the section instead of carrying the half-pair.
