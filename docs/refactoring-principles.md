# Refactoring Principles

_Last updated: 2026-06-03_

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
| Split by invariant, not line count | file-size ratchet warning + reviewer checklist |
| Reducers decide | domain import rules; view-side `Task { try? await ... }` warnings |
| Adapters translate | boundary import script for `domain/` and adapter modules |
| Protocol changes are product changes | protocol version parity + fixture coverage checks |
| Async failures are observable | SwiftLint custom rule for side-effecting `try? await` |
| Secrets are not preferences | secret-field lint on settings persistence |
| HUD requires measurement | checklist + signpost comparison for HUD PRs |

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
