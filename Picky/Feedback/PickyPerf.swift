//
//  PickyPerf.swift
//  Picky
//
//  Lightweight `OSSignposter` wrapper for HUD performance instrumentation.
//
//  Compiled out of Release builds via `#if DEBUG` so signposts never reach
//  end-user environments — `package-signed-app.sh` ships Release and
//  `run-dev-signed-app.sh` ships Debug (see scripts). On Debug the helpers
//  emit standard `os_signpost` markers under subsystem
//  `com.jonghakseo.picky` + category `hud-perf`; capture in Instruments via
//  the Logging or Time Profiler templates and filter by that subsystem.
//
//  Usage:
//    PickyPerf.interval("name") { ... work ... }
//    PickyPerf.event("name")
//
//  See docs/perf-profiling.md for the full HUD profiling playbook.
//

import Foundation
import os.signpost

enum PickyPerf {
    #if DEBUG
    static let signposter = OSSignposter(subsystem: "com.jonghakseo.picky", category: "hud-perf")

    /// Wrap a synchronous chunk of work in a signpost interval. Returns the
    /// inner closure's value so call sites stay expression-shaped.
    @inlinable
    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try work()
    }

    /// Emit a one-shot event signpost. Useful for marking SwiftUI body
    /// re-evaluations or NSViewRepresentable lifecycle calls where the work
    /// itself is not wrappable as an interval.
    @inlinable
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
    #else
    /// Release-build no-op: the closure still runs (so behavior matches
    /// Debug) but no signpost is emitted. The `@inlinable` attribute lets
    /// the optimizer drop the call frame entirely at the call site.
    @inlinable
    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        try work()
    }

    /// Release-build no-op.
    @inlinable
    static func event(_ name: StaticString) {}
    #endif
}
