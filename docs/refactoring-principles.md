# Refactoring Principles

_Last updated: 2026-08-30_

Use this document before structural refactors in Picky. It complements `ARCHITECTURE.md`, `docs/swift-concurrency.md`, and `docs/perf-profiling.md`.

## One-line rule

> Preserve invariants first, then extract pure policies; never split a facade just to reduce line count.

## 1. Scope and safety gates

Before changing structure, write down:

- the invariant or ownership boundary being improved;
- the characterization tests that currently prove behavior;
- the validation command that must pass after the change;
- the user-visible failure mode the change is meant to reduce.

If none of these can be stated, do not refactor yet.

## 2. Core mental models

### 2.1 Reducers decide; managers execute effects

State transitions should live in pure reducers/policies. Managers and view models may orchestrate effects, but they should not hide business rules inside network, file, UI, or audio side-effect code.

Good pattern in this repo:

- `Picky/Interaction/PickyInteractionReducer.swift`

Target direction:

```text
Event/Input -> pure reducer/policy -> state + explicit effects -> effect runner/adapter
```

### 2.2 Adapters translate; domain owns invariants

Adapters exist to translate external APIs into Picky's internal model:

- WebSocket server/client
- Pi SDK runtime
- AppKit/SwiftUI views
- filesystem/keychain stores

Adapters should not become owners of durable rules such as:

- session status transitions;
- queue ordering and queue item identity;
- duplicate quick-reply/TTS suppression;
- archive/unread notification policy;
- dock projection and grouping rules;
- protocol compatibility assumptions.

Those belong in domain/application policies with tests.

### 2.3 Split by invariant, not by line count

Large files are a signal, not a root cause. A split is useful only when it creates a clearer owner for a coherent invariant.

Bad split:

```text
PickyHUDViewPart1.swift
PickyHUDViewPart2.swift
PickyHUDViewHelpers.swift
```

Better split:

```text
PickyHUDKeyboardShortcutPolicy.swift
PickyHUDOpenClosePolicy.swift
PickyHUDResizeInteractionPolicy.swift
```

### 2.4 One mutable state owner per cluster

Every state cluster should have one owner. Other code should ask that owner to mutate state rather than duplicating mutation rules.

Important clusters:

- session projection;
- dock layout and grouping;
- composer drafts and attachment paths;
- inline/shell terminal attachment state;
- voice input lifecycle;
- pointer overlay presentation;
- settings preferences;
- secrets.

If two objects can both mutate the same cluster, introduce an owner or a pure policy.

### 2.5 Every async user action must fail visibly or observably

Avoid silently dropping failures from user-visible actions.

High-risk pattern:

```swift
Task { try? await viewModel.abort(sessionID: sessionID) }
```

Preferred outcomes:

- surface a UI error;
- write a structured log;
- update test-observable error state;
- provide a retry path;
- explicitly document that the failure is safe to ignore.

`try? await Task.sleep(...)` for cancellation-friendly timing can be acceptable, but side-effecting commands should not disappear silently.

### 2.6 Protocol changes are product changes

Any app-daemon protocol change must update the whole contract set:

- Swift model in `Picky/PickyAgentProtocol.swift`;
- TypeScript schema in `agentd/src/protocol.ts`;
- fixtures under `contracts/protocol`;
- Swift tests in `PickyTests/ProtocolContractTests.swift`;
- TypeScript tests in `agentd/src/protocol.test.ts`.

Do not rely on one side's tests alone.

### 2.7 HUD optimization requires measurement

SwiftUI/AppKit hybrid UI can regress through identity, body fan-out, and layout reentry even when the code looks cleaner.

Before and after HUD refactors that affect rendering or view identity:

1. read `docs/perf-profiling.md`;
2. use existing `PickyPerf` signposts or add focused temporary signposts;
3. compare signpost count/duration;
4. avoid broad structural changes unless the profile supports them.

### 2.8 Swift concurrency stays MainActor-first

Follow `docs/swift-concurrency.md`.

- UI/view models start on `@MainActor`.
- Move only proven-heavy pure work off the main actor.
- Avoid unbounded `Task {}` creation in rows/views.
- `Task.detached` is an escape hatch, not a default.
- Do not block async code with semaphores.

### 2.9 Picky captures neutral context; Pi interprets intent

Picky should not duplicate Pi's skill/tool/workflow policy.

Allowed in Picky:

- neutral context capture;
- session UI and long-running Pickle UX;
- local app/daemon protocol;
- visible extension UI bridge;
- user settings and local runtime orchestration.

Not allowed in Picky:

- hard-coded URL/app-name task routing;
- reimplementing Pi skills/MCP policy;
- hidden SaaS/backend assumptions;
- changing prompt semantics to force a workflow unless the user explicitly asked.

## 3. Static-rule mapping

These mental models should gradually become static checks.

| Mental model | Static guard |
|---|---|
| Split by invariant, not line count | file-size ratchet warning + reviewer checklist (thresholds: 3.1) |
| Reducers decide | domain import rules; view-side `Task { try? await ... }` warnings |
| Adapters translate | boundary import script for `domain/` and adapter modules |
| Protocol changes are product changes | protocol version parity + fixture coverage checks |
| Async failures are observable | SwiftLint custom rule for side-effecting `try? await` |
| Secrets are not preferences | secret-field lint on settings persistence |
| HUD requires measurement | checklist + signpost comparison for HUD PRs |

### 3.1 SwiftLint error thresholds are recorded debt

`.swiftlint.yml` keeps every size and complexity rule warning-first, with the `error`
value pinned just above the current worst offender. The error line is not a quality
target: it is a ratchet that fails immediately when the worst case regresses, while
2.3 still forbids splitting a facade only to satisfy a line count.

A threshold may only be raised with an explicit decision recorded here.

#### 2026-08-25 re-pin

The pre-push hook downgraded every error-severity violation to a warning because
`printf ... | grep -q` returns SIGPIPE under `set -o pipefail`, so the escalation
branch never ran. With the gate silent, four thresholds drifted:

| Rule | Old error pin | Pin claimed | Actual worst | New pin |
|---|---:|---:|---:|---:|
| `file_length` | 3900 | 3806 | 4883 | 5000 |
| `type_body_length` | 3400 | 3308 | 4251 | 4350 |
| `function_body_length` | 150 | 122 | 196 | 210 |
| `cyclomatic_complexity` | 35 | 30 | 45 | 50 |

Offenders: `PickyTests/PickySessionViewModelTests.swift` (file/type length) and
`Picky/Interaction/PickyInteractionEvent.swift` plus
`Picky/Interaction/PickyInteractionReducer.swift` (complexity, body length).

Decision: re-pin to the measured worst case rather than refactor under a gate
repair. The three files are exactly the kind of large facade 2.3 says not to split
for a line-count gate, and doing so while fixing the hook would mix an unrelated
structural change into a tooling fix. The debt is now visible and enforced instead
of silently growing.

Follow-up: `PickyInteractionEvent`/`PickyInteractionReducer` complexity is
dispatch-switch shaped, so it should shrink through 2.1 (reducers decide) rather
than mechanical extraction. Tighten each pin to the new worst case when it does.

#### 2026-08-29 test length exception

Test suites accumulate independent regression cases, so file and suite body length
do not measure production ownership or facade complexity. `PickyTests` therefore
inherits the app lint configuration through `.swiftlint-tests.yml` but disables
only `file_length` and `type_body_length`. All other SwiftLint rules still apply.

Removing tests from the production length ratchets lowered both app-only error pins
to 2450. A 2026-08-30 SwiftLint run measured app maxima of 2376 lines for
`file_length` and 2367 lines for `type_body_length`, both in `PickySessionViewModel`.

#### 2026-08-31 runtime model-scope exceptions

Global model-scope support added wire-contract fields to `PickyAgentProtocol.swift`
and Pi settings/session orchestration to `pi-sdk-runtime.ts`. The architecture guard
measured 1509 and 1539 lines respectively, just above its 1500-line production-file
threshold.

Decision: pin both files to those exact measured counts. The protocol file remains
the single app-daemon contract decoder, and `PiSdkRuntime` remains the adapter that
owns Pi session creation and runtime mutations. Splitting either only to cross the
line-count threshold would not create a clearer invariant owner. Protocol contract,
Pi runtime, model-resolution, and global settings CAS tests characterize the added
behavior. These pins may only stay level or shrink; a future extraction must move a
coherent contract or runtime responsibility with its tests.

#### 2026-09-03 dock manual order extraction

The `PickySessionViewModel.swift` ratchet blocked a push at 2884 lines against a
2879 pin. Rather than reformat the growth away, the dock ordering rules moved to
`Picky/Sessions/PickyDockManualOrderPolicy.swift`: universe reconciliation,
drop-index translation over interleaved archived slots, and unarchive promotion
to the newest slot.

This satisfies 2.3 because it creates an owner for a real invariant. The visible
space (`sessions.reversed()`) and underlying space conversion previously appeared
as open-coded `(N - 1) - index` arithmetic at three call sites, and the reason a
drop index cannot index `manualOrder` directly (archived ids keep their slots)
lived only in a comment.

The file measured 2853 lines afterwards, so the pin drops to 2860. The 278
existing `PickySessionViewModelTests` characterize the facade and
`PickyDockManualOrderPolicyTests` now pins the extracted rules directly.

## 4. Review checklist

For each structural PR, reviewers should ask:

1. What invariant became clearer or better owned?
2. Which characterization test would fail if behavior changed?
3. Did the change reduce side-effect coupling or just move code?
4. Are user-visible async failures observable?
5. Did protocol changes update both languages and fixtures?
6. Did HUD changes preserve identity/performance evidence?
7. Are static-rule warnings intentionally accepted or being reduced?

## 5. Recommended first extraction pattern

Use this sequence for safe refactors:

1. Add focused characterization tests.
2. Extract a pure function/policy with no side effects.
3. Keep the old facade method signature stable.
4. Route the facade through the extracted policy.
5. Run targeted tests.
6. Ask `verifier`/`reviewer`/`challenger` to stress the result.
7. Commit as one small checkpoint.

## 6. References

- Current architecture: `ARCHITECTURE.md`
- Swift concurrency guide: `docs/swift-concurrency.md`
- HUD performance playbook: `docs/perf-profiling.md`
- SwiftLint rules: https://realm.github.io/SwiftLint/rule-directory.html
- typescript-eslint rules: https://typescript-eslint.io/rules/
- GitHub Actions workflow syntax: https://docs.github.com/actions/reference/workflows-and-actions/workflow-syntax
