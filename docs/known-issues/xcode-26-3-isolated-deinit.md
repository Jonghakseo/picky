# Open issue: Xcode 26.3 miscompiles implicit isolated deinit

Status: open. The build toolchain stays on **Xcode 16.3 (16E140)**. Xcode 26.3
(17C529, swiftlang-6.2.4.1.4) cannot build or run Picky reliably. Two distinct
failures were traced to the same language change; one is fixed in source, the
other is unresolved and blocks the upgrade.

Do not switch `xcode-select` to 26.3 until the remaining item is closed. CI
(`macos-15`) uses Xcode 16.x, which is why this never turned CI red.

## Why this happens

Swift 6.2 makes `deinit` of a global-actor-isolated class implicitly isolated.
The project compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
*every* class without explicit isolation is `@MainActor` and gets a synthesized
isolated deinit. With `MACOSX_DEPLOYMENT_TARGET = 14.2` that deinit hops through
`swift_task_deinitOnExecutorMainActorBackDeploy`, emitted into our own binary.

Upstream: swiftlang/swift#87316, swiftlang/swift#88036.

## Failure 1 — Release compiler crash (fixed)

`swift-frontend` crashes while optimizing the synthesized deinit:

```
While running pass SILFunctionTransform "EarlyPerfInliner"
  on SILFunction "@$s5Picky0A26TerminalOverlayRecordStoreCfD"
  for 'deinit' (at Picky/Sessions/PickyTerminalOverlay.swift:121:13)
```

Minimal reproduction (14 lines, crashes with `-O -default-isolation MainActor`):

```swift
@MainActor
final class RecordStore<Record> {
    private struct ActiveRecord {
        let recordID: ObjectIdentifier
        let record: Record
    }
    private var active: [ActiveRecord] = []
    private var pending: [ObjectIdentifier: Record] = [:]
}
```

Trigger is the combination of **generic + `@MainActor` + `-O`**. Narrowing runs:

| Variant | Result |
| --- | --- |
| generic + `@MainActor` + `-O` | crash |
| non-generic | ok |
| no `@MainActor` | ok |
| `-Onone` (Debug) | ok |
| explicit `nonisolated deinit {}` | ok |

`PickyTerminalOverlayRecordStore` is the only generic class in the project, so
an explicit `nonisolated deinit {}` there is sufficient. Its generic parameter
is a real test seam (production uses `TerminalRecord`, tests use `RecordToken`),
so de-genericizing was not an option.

## Failure 2 — Debug runtime heap corruption (partly fixed)

The back-deployed deinit hop double-frees during task-local teardown:

```
___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED
  swift::TaskLocal::StopLookupScope::~StopLookupScope()
  swift_task_deinitOnExecutorImpl
  swift_task_deinitOnExecutorMainActorBackDeploy
  PickySessionDockLayoutController.__deallocating_deinit
```

Adding `nonisolated deinit {}` to the `@MainActor` classes that XCTest suites
release inline removed these aborts. Applied to
`PickySessionDockLayoutController`, `PickySessionSlashCommandController`, and
`PickySessionComposerDraftController`.

### Why the fix is version-guarded

`nonisolated deinit` is Swift 6.2 syntax. On Xcode 16.3 it fails with
`'isolated' deinit requires frontend flag -enable-experimental-feature
IsolatedDeinit`. Every occurrence is therefore wrapped:

```swift
#if compiler(>=6.2)
    nonisolated deinit {}
#endif
```

Unguarded, these annotations break the current build toolchain and CI. Remove
the guards and the annotations together once 26.3 (or later) is adopted.

## Remaining blocker — `PickyGitRepositoryStatus` refresh path

`PickyGitRepositoryStatusTests.refreshCacheReusesFreshValueUntilTTLExpires()`
kills the XCTest host on 26.3 and passes on 16.3. It is flaky: a full run needed
10–12 host restarts before completing.

```
swift_retain                                     <- SIGBUS, KERN_PROTECTION_FAILURE
ManualGitStatusLoader.load(cwd:)                 <- retaining the captured loader
closure #1 in closure #1 in PickyGitRepositoryStatusRefreshCache.refreshOnce
thunk for @escaping @isolated(any) @callee_guaranteed @async () -> (@out A)
completeTaskWithClosure
```

`swift_retain` writes a refcount into a read-only page, so the captured context
pointer is garbage rather than a freed heap object.

This is **not** test-only. A Debug app built with 26.3 died ~3.8s after launch
in the same path. `PickyGitRepositoryStatus.prefetchIfNeeded` runs for every
Pickle card, so 26.3 Debug builds are unusable until this is fixed.

### Hypotheses already falsified

Recording these so they are not retried:

1. **Binding `self.loader` to a local before the `Task`.** No effect.
2. **`nonisolated deinit {}` on `PickyGitRepositoryStatusRefreshCache` and the
   test's `ManualGitStatusLoader`.** No effect. This crash is not a deinit
   crash, unlike Failure 2.
3. **Hoisting the `Task` out of the `withCheckedContinuation` body** (splitting
   waiter registration from waiting). No effect; reverted.
4. **Raising `MACOSX_DEPLOYMENT_TARGET` to 15.0.** Verified applied
   (`-target arm64-apple-macos15.0`) and the crash persisted, so the
   back-deploy shim is not the cause of the compiler crash. macOS 14.2 support
   does not need to be dropped.
5. **Disabling the language feature.** `-disable-experimental-feature
   IsolatedDeinit` and `-disable-upcoming-feature IsolatedDeinit` are both
   ignored; isolated deinit is standard in 6.2.
6. **A standalone reproduction** of the cache plus a manual continuation-based
   loader, compiled with the project's exact frontend flags, survives 20,000
   rounds. The crash appears to need the XCTest host context.

`-Xllvm -sil-inline-caller-benefit-reduction-factor=0` does avoid Failure 1, but
it retunes the inliner globally and was rejected.

### Suggested next step

Treat it as a redesign rather than another workaround. The suspect construct is
`PickyGitRepositoryStatusRefreshCache` storing `CheckedContinuation`s in a
dictionary and resuming them from a detached `Task`. Replacing that with an
`actor` or an `AsyncStream`-based coalescer would remove the pattern entirely.
Characterization tests for the current stale-while-revalidate and
generation-invalidation semantics must come first — see
`docs/refactoring-principles.md`.

## How to verify a fix

```bash
# Must stay green on the current toolchain
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO test

# Must stop restarting the host on 26.3
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath /tmp/Picky263DD -parallel-testing-enabled NO \
  test -only-testing:PickyTests/PickyGitRepositoryStatusTests
```

Grep the log for `Restarting after unexpected exit`; `xcodebuild` reports
`** TEST FAILED **` without a per-test failure when the host dies.

Always build into a toolchain-specific `-derivedDataPath`. Reusing one across
Xcode versions fails at link time with missing `___swift_coroFrameAllocStub`.
