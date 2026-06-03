# Swift Concurrency Guidelines

This is the canonical guidance for using Swift Concurrency in Picky's Swift/SwiftUI code. The goal is simple, predictable concurrency: start on the main actor, measure before optimizing, and move only proven-heavy work off the main actor.

One-liner: **Start UI on MainActor and keep it simple; only split off the bottlenecks that Instruments actually proves.**

## When to use

- Adding or refactoring async code in `Picky/` (HUD, session view models, context capture, voice).
- Deciding whether to introduce an `actor`, a `Task`, `Task.detached`, or a custom executor.
- Migrating existing GCD code to Swift Concurrency.

## Core principles

1. **Start UI/ViewModels on `@MainActor`.** SwiftUI/AppKit views, observable state, and state mutations begin on the main actor. Don't reach for background concurrency by default.

2. **Don't guess at lag — confirm with Instruments.** If something feels slow (HUD rendering, session list, log/message rendering, context capture), profile first. See `docs/perf-profiling.md`.

3. **Only split off proven bottlenecks.** Move just the genuinely heavy pure work off the main actor (JSON parsing, diffing, log processing, file IO, image processing) using the repository's current structured-concurrency/background-helper patterns. Leave everything else where it is, and re-check toolchain-specific attributes such as `@concurrent` before introducing them.

4. **Keep actors few.** Introduce an `actor` only where there is a clear domain boundary with shared mutable state (session store, daemon client, artifact store). Don't actor-ify everything.

5. **Don't create Tasks en masse.** Avoid `Task {}` per row/message/view. Prefer batching, debounce, a single worker, and structured concurrency.

6. **`Task.detached` is not the default background tool.** Use it only when you have a concrete reason to break out of the current actor context. It is not a general-purpose "run in background" helper.

7. **Never block async with a semaphore.** Blocking async flow with a semaphore risks deadlock, priority inversion, and MainActor stalls. Keep async flows async all the way through.

8. **Turn on strict concurrency checking in Swift 5 first.** Clean up incrementally on warnings before any large Swift 6 migration.

9. **Custom executors are a last resort.** Almost never needed in app/UI code. Only consider one for a special bottleneck that Instruments has proven.

10. **Don't rewrite GCD wholesale for "performance".** Migrate incrementally around real problem spots, not in one sweeping rewrite.
