//
//  PickyPerf.swift
//  Picky
//
//  Lightweight `OSSignposter` wrapper for HUD performance instrumentation.
//  Signposts are zero-cost when nothing is recording, so call sites can stay
//  on the hot path in release builds without measurable overhead. Capture in
//  Instruments via the Logging or Time Profiler templates and filter by
//  subsystem `com.jonghakseo.picky` + category `hud-perf`.
//

import Foundation
import os.signpost

enum PickyPerf {
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
}
