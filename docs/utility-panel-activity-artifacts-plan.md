# Utility panel redesign: Activity + Artifacts tabs

Status: plan v2 (2026-08-15, revised after stress-interview review). Replaces the Pickle utility panel `변경사항` (changes) tab with an `활동` (activity) tab and adds a `작업물` (artifacts) tab.

## Motivation

The changes tab (whole-repo unstaged/staged git diff, read-only) is rarely used: it is passive, scoped to the repository instead of the Pickle's own work, and meaningless for non-coding Pickles. Meanwhile the data for two higher-value surfaces largely exists in the backend: per-session tool activity (`session.tools`) and session artifacts (`session.artifacts`).

## Confirmed product decisions

1. Tabs become `터미널 | 활동 | 작업물`. The changes tab is removed; per-file diff is absorbed into activity file rows (P2).
2. Investigation tool runs (consecutive `read`/`rg`-style calls) auto-collapse in the activity timeline.
3. No auto tab switching on completion; badges only.
4. Artifacts tab is **files only**: no links, no reports, no `register_artifact` tool.
5. The conversation-card artifact tray (`PickyArtifactTrayView`) keeps its current behavior for links/reports; file artifacts must **not** appear in it.

## Artifact definition (final)

An artifact is a **non-source file the session created or updated** (documents, data, images: `md`, `csv`, `json` reports, `png`, `svg`, `pdf`, `html`, `xlsx`, …). "Created or updated" is deliberate: Pi `write` is create-or-overwrite and pre-write existence alone cannot prove novelty, so both count; capture records `fileExistedBefore` so the UI can label 생성/갱신.

Capture paths — exactly two:

1. `write` tool events carrying a **structured file path** (see data contract below), filtered by a non-source extension allowlist.
2. Local file paths explicitly mentioned in assistant answer text, reusing the extraction family of `extractChangedFilesFromExplicitText` (`agentd/src/artifact-store.ts:184`). Runs at both the `waiting_for_input` assistant-text flush and the terminal flush (same dual-flush pattern the link materializer already uses), deduped via deterministic ids (`file-` + path hash) through `mergeArtifacts`.

Exclusions (anti-noise):

- URLs/links (owned by the tray via `artifact-store.ts`), reports, tool log/preview paths.
- Source-code files: `edit`/`write` on source belongs to the activity tab's changed-file rows.
- Hidden/temp files, `node_modules`, build output directories.
- Re-registration of the same path updates `updatedAt` (reuse `mergeArtifacts`, `agentd/src/domain/artifacts.ts:3`) and re-arms the unseen badge instead of adding a duplicate row.
- A later-deleted file keeps its row with a "deleted" state (reuse `PickyArtifactTrayPresentation.PrimaryAction.missingPath`).

Known heuristic limits (accepted): extension allowlist misses unlisted/extension-less outputs and may over-capture repo-doc overwrites (e.g. `README.md`). Mitigations: allowlist is one constant; final-answer mention capture requires the file to exist on disk at extraction time; the 생성/갱신 label keeps overwrites honest. Revisit with real-session sampling after P0 ships; `register_artifact` stays rejected.

## Data contracts

### File path capture (P0, blocking)

`argsPreview` is display-only and truncated to 500 chars (`agentd/src/domain/pi-event-normalizer.ts`); it must never be parsed for provenance. Instead the Pi SDK runtime adapter (`agentd/src/runtime/pi-sdk-runtime.ts`) resolves the raw `write` args against the session cwd at tool-start and attaches to the internal `RuntimeEvent.tool`:

- `filePath` (normalized absolute path)
- `fileExistedBefore` (checked at tool-start, before the write lands — avoids the post-success race)

`runtime-event-handler.ts` materializes the `kind:"file"` artifact on the matching success event using these fields only. Existence re-check failures at success time still register the artifact (the deleted-state row covers files that vanish later).

### Artifact model

- `PickyArtifactSchema.kind` is already a free-form string (`agentd/src/protocol.ts:138`); file artifacts use `kind: "file"` with `path` set. No breaking protocol change.
- One `session.artifacts` array, disjoint surface filters — **enforced on both surfaces**: the artifacts tab renders only `kind == "file"`; the tray input filters `kind != "file"` (tray keeps showing links/reports as today; existing tray tests extended with a mixed link+file regression case, including "files only → no empty tray row").

### Tool activity

- Activity tab consumes `session.tools` (`PickyToolActivity`, `agentd/src/protocol.ts:145`).
- **Snapshot cap**: initial `sessionSnapshot` trims tools to the last 200 (`SNAPSHOT_TOOL_LIMIT`, `agentd/src/server.ts:1186`). Live sessions converge via `sessionUpdated`; reconnected finished sessions do not. P0 renders what the snapshot provides; P1 adds a `getSessionToolHistory` request (fired on first activity-tab open) that returns the full list.
- **Turn identity (P1)**: optional `turnIndex` on `PickyToolActivitySchema`. The counter is owned by `SessionSupervisor`/message journal (which already own turn boundaries via `commitTurnActivity` and `agent_activity` entries), not by `runtime-event-handler.ts`. Rules for restart/resume/rewind are defined there; tools without `turnIndex` (legacy sessions) group into a single trailing "이전 활동" bucket. Optional field keeps old persisted sessions decodable.

## UX spec

### Activity tab

- Summary strip: 커맨드(bash) / 파일(edit+write) / 에이전트 / 실패 counts + elapsed time. Commands/files come from `agentd/src/domain/tool-categorizer.ts`; **agent count and the 에이전트 filter need new support** — the categorizer maps subagents to `other` and `PickyToolHistoryFilterPolicy` has no agent category (only the display-level `PickyToolHistoryDisplayCategory.agent`). P0 extends the filter policy with an agent category driven by `subagentSummary` presence; failures are status-based, not category-based.
- Filter chips: 전체 / 파일 / 커맨드 / 에이전트 / 실패.
- Timeline, newest first, grouped by turn (P1). Running tools pinned in a `지금` section with a pulse dot.
- Consecutive read-only investigation calls collapse into one expandable row (`read ×5 · rg ×3`).
- Row actions: file rows → open in editor / reveal via `PickyToolHistoryFilePathPolicy` **extended with a session-cwd input** so relative paths (the common case in tool records) resolve; bash rows → copy command, view full result; failed bash rows additionally → "후속 지시로 보내기" (prefills the composer with the failure preview).
- File rows expand inline to a per-file diff (P2). `getSessionDiff` takes no path and Swift keeps one `PickySessionDiffState` per session, so per-row fetches would clobber each other: P2 fetches the whole diff once per expansion, caches per path in a per-session store, and defines stale-response/staged-vs-unstaged rules. No new protocol message.
- Tab badge: pulse dot while any tool is running; red dot when the latest turn contains a failure.
- **Detached `PickyToolHistoryViewer` parity**: the window currently provides search/⌘F, turn-vs-session scope, refresh, and is deep-linked from conversation rows (live tool row, `agent_activity` rows) with turn scope. The window and its entry points **stay until parity lands** (P2): entry points then reroute to the activity tab carrying the turn scope, the pop-out button preserves scope, and parity is regression-tested before the old window is removed.

### Artifacts tab

- Flat list, newest first: icon, filename, directory (`~`-abbreviated), 생성/갱신 label, relative time.
- Row actions: 열기 / Finder / 경로 복사. This exceeds `PickyArtifactTrayPresentation`'s single-`primaryAction` model, so the tab gets a small dedicated row-action policy (open file / reveal / copy path) that reuses the tray's path-resolution and `missingPath` logic.
- Deleted files: dimmed row, strikethrough name, "경로 복사" only.
- Tab badge: count of artifacts added/updated since last viewed.
- **Unseen state owner (P0)**: no per-session utility UI state store exists today (tab selection is an in-memory `@State` dictionary in `PickyHUDView`; only panel height persists). P0 introduces a UserDefaults-backed per-session store holding `selectedTab` + `lastSeenArtifactsAt`, with cleanup on session removal/archive pruning. Mark-seen fires only while the tab is selected **and** the HUD is visible; an artifact updated while visible is immediately seen. No `changes`-value migration is needed since current selection was never persisted.
- Empty state explains the capture rule ("세션이 새로 만든 문서·데이터·이미지 파일이 여기에 모여요").

## Implementation phases

### P0 — tab replacement + file capture

agentd:

- Runtime adapter: structured `filePath`/`fileExistedBefore` on `write` tool events (`runtime/types.ts`, `pi-sdk-runtime.ts`), with adapter-side path normalization against session cwd.
- `agentd/src/domain/file-artifacts.ts` (new): allowlist + exclusion rules; pure functions consuming the structured fields and final-answer text.
- `runtime-event-handler.ts`: materialize `kind:"file"` on write success; extract final-answer file mentions at both `waiting_for_input` and terminal flushes; emit `artifactUpdated`.
- Vitest: new domain module, handler wiring, normalizer/adapter contract (relative/absolute/`~`/unicode paths, >500-char args).

Swift:

- `PickyHUDUtilityPanelTab`: `.changes` → `.activity` + `.artifacts`.
- Per-session utility UI state store (selected tab + lastSeenArtifactsAt) with cleanup.
- Activity tab content: port `PickyToolHistoryEntry` list rendering into a panel view (`PickySessionActivityView`), flat list + filter chips (agent category added to `PickyToolHistoryFilterPolicy`), `LazyVStack` for long histories (budget per `docs/perf-profiling.md`). Detached viewer untouched.
- Artifacts tab content: `PickySessionArtifactsView` (`kind == "file"`), dedicated row-action policy; tray input filtered to `kind != "file"` with mixed-array regression tests.
- Badge: unseen file-artifact count in the renamed `changesBadgeCount` slot.
- `PickySessionChangesView` and diff plumbing stay unreferenced by the panel (removal in P2).
- Swift Testing: filter-policy characterization (before extension), tray filtering, unseen-count policy, path policy with cwd.

### P1 — timeline 고도화

- `turnIndex` (supervisor-owned counter, protocol optional field, Swift decode, legacy bucket).
- `getSessionToolHistory` full-history request on first tab open (lifts the 200-cap for reconnected sessions).
- Turn grouping, investigation-run collapsing (pure policy + tests), summary strip (incl. agent count), running-section pinning, failure red-dot badge, failed-row composer prefill.

### P2 — diff absorption + viewer absorption + cleanup

- Inline per-file diff: whole-diff fetch + per-path cache + stale/concurrency rules; then delete `PickySessionChangesView` and unused diff-state plumbing (keep `PickyDiffPreview` and git diff domain).
- Tool-history parity: search, turn scope reroute from conversation entry points, scope-preserving pop-out; remove the detached window only after parity regression tests pass.
- Localization cleanup: remove unreferenced `hud.changes.*` keys, add `hud.activity.*` / `hud.artifacts.*`.

## Testing strategy

Follow `docs/refactoring-principles.md`: characterization tests before porting (`PickyToolHistoryFilterPolicy`, tray presentation), pure policy modules first (file-artifact rules, collapse grouping), warning-first on structure. Protocol changes are contract-tested on **both sides**: `agentd/src/protocol.test.ts` round-trips, `contracts/protocol` fixtures, and `ProtocolContractTests.swift`, including legacy decode without the new optional fields.

## Risks

- **Heuristic precision**: repo-doc overwrites over-capture; unlisted formats under-capture. Accepted for P0 (see definition section); revisit with real-session sampling.
- **HUD perf**: hundreds of tool rows; lazy rendering + collapsed investigation runs bound visible rows.
- **Adapter coupling**: structured path capture depends on Pi SDK write-args shape; covered by adapter contract tests so SDK bumps fail loudly.

## Review log

Stress-interview (verifier/reviewer/challenger, 2026-08-15) findings incorporated in v2: tray contamination guard, structured write-path capture replacing argsPreview parsing, created-or-updated provenance, snapshot 200-cap handling, supervisor-owned turn identity, unseen-state store design, tool-history viewer parity gate, dual-flush answer extraction, session-cwd path resolution, per-file diff caching design, both-sides contract tests, corrected `extractChangedFilesFromExplicitText` location.
