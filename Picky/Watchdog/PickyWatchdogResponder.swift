//
//  PickyWatchdogResponder.swift
//  Picky
//
//  Decides what to do when the watchdog reports main-thread trouble. Two
//  edges, two jobs: the soft-stall edge captures a sample while the stall is
//  still happening, and the later spin edge shows the "Picky is not
//  responding" dialog. Binding both to the spin edge (as this used to) meant
//  `sample` started right as the main thread recovered, so every captured
//  window trailed the hang it was supposed to explain.
//

import Foundation
import os

/// Describes the stall that triggered a capture, so the resulting file can say
/// whether it actually covers the hang.
struct PickyWatchdogCaptureContext: Equatable {
    enum Trigger: String, Equatable {
        /// Fired at the soft-stall threshold, while the stall is in progress.
        case softStall
        /// Fired at the spin threshold. Late by construction — only used when
        /// no soft-stall capture exists for the current stall.
        case spin
    }

    var trigger: Trigger
    var heartbeatAgeAtStart: TimeInterval
    var stallStartedAt: Date?
}

final class PickyWatchdogResponder {
    /// Captures `/usr/bin/sample` output to disk. Returns the resulting file path.
    protocol SampleCapturing {
        func captureSpinSample(pid: Int32, context: PickyWatchdogCaptureContext) throws -> URL
    }

    /// Launches the alert helper process and reports back when the helper exits.
    protocol HelperLaunching {
        func launchHelper(parentPid: Int32, samplePath: URL, completion: @escaping () -> Void)
    }

    /// Where blocking capture work runs. Kept off the watchdog's poll queue so
    /// a multi-second `sample` run cannot delay spin detection. Tests inject a
    /// synchronous executor.
    typealias Executor = (@escaping () -> Void) -> Void

    private let pid: Int32
    private let capturer: SampleCapturing
    private let launcher: HelperLaunching
    private let clock: () -> Date
    private let captureCooldown: TimeInterval
    private let executor: Executor
    private let log = Logger(subsystem: "com.jonghakseo.picky", category: "watchdog.responder")

    private let lock = NSLock()
    private var isHandling = false
    private var isCapturing = false
    private var lastCaptureStartedAt: Date?
    private var lastSample: (url: URL, startedAt: Date)?
    private var currentStallStartedAt: Date?

    /// Reports current main-thread heartbeat staleness, used to describe a
    /// spin-edge capture. Assigned after construction because the watchdog
    /// that answers it is built later.
    var heartbeatAge: () -> TimeInterval? = { nil }

    init(
        pid: Int32,
        capturer: SampleCapturing,
        launcher: HelperLaunching,
        clock: @escaping () -> Date = Date.init,
        captureCooldown: TimeInterval = 60,
        executor: Executor? = nil
    ) {
        self.pid = pid
        self.capturer = capturer
        self.launcher = launcher
        self.clock = clock
        self.captureCooldown = captureCooldown
        let queue = DispatchQueue(label: "com.jonghakseo.picky.watchdog.capture", qos: .utility)
        self.executor = executor ?? { work in queue.async(execute: work) }
    }

    /// Called when the heartbeat first goes stale past the soft threshold.
    /// This is the only edge that produces a trustworthy sample, because the
    /// stall is still in progress. Rate-limited: on a starved machine the
    /// stalls come in bursts and spawning `sample` for each one would add to
    /// the very load being diagnosed.
    func handleSoftStallDetected(age: TimeInterval) {
        let now = clock()

        lock.lock()
        if currentStallStartedAt == nil {
            currentStallStartedAt = now.addingTimeInterval(-age)
        }
        let stallStartedAt = currentStallStartedAt
        let withinCooldown = lastCaptureStartedAt.map { now.timeIntervalSince($0) < captureCooldown } ?? false
        if isCapturing || withinCooldown {
            lock.unlock()
            return
        }
        isCapturing = true
        lastCaptureStartedAt = now
        lock.unlock()

        executor { [weak self] in
            self?.performCapture(
                context: PickyWatchdogCaptureContext(
                    trigger: .softStall,
                    heartbeatAgeAtStart: age,
                    stallStartedAt: stallStartedAt
                ),
                startedAt: now
            )
        }
    }

    /// Called when the heartbeat advances again. Ends the current stall so the
    /// next one cannot reuse this stall's sample.
    func handleStallRecovered() {
        lock.lock()
        currentStallStartedAt = nil
        lock.unlock()
    }

    /// Called by the watchdog when the main thread is judged unresponsive.
    /// Safe to call from any thread. Repeat calls during a single handling
    /// pass collapse into one user-visible alert.
    func handleSpinDetected() {
        lock.lock()
        if isHandling {
            lock.unlock()
            return
        }
        isHandling = true
        lock.unlock()

        executor { [weak self] in
            self?.performSpinResponse()
        }
    }

    // MARK: - Work

    private func performCapture(context: PickyWatchdogCaptureContext, startedAt: Date) {
        defer {
            lock.lock()
            isCapturing = false
            lock.unlock()
        }
        do {
            let url = try capturer.captureSpinSample(pid: pid, context: context)
            lock.lock()
            lastSample = (url, startedAt)
            lock.unlock()
        } catch {
            log.error("sample capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performSpinResponse() {
        lock.lock()
        let stallStartedAt = currentStallStartedAt
        let reusable: URL? = lastSample.flatMap { sample in
            guard let stallStartedAt, sample.startedAt >= stallStartedAt else { return nil }
            return sample.url
        }
        lock.unlock()

        let samplePath: URL
        if let reusable {
            samplePath = reusable
        } else {
            // No in-stall sample: the cooldown skipped it, or the stall crossed
            // both thresholds inside one poll tick. Capture now and let the
            // header flag the window as late.
            let context = PickyWatchdogCaptureContext(
                trigger: .spin,
                heartbeatAgeAtStart: heartbeatAge() ?? 0,
                stallStartedAt: stallStartedAt
            )
            let startedAt = clock()
            do {
                samplePath = try capturer.captureSpinSample(pid: pid, context: context)
                lock.lock()
                lastSample = (samplePath, startedAt)
                lastCaptureStartedAt = startedAt
                lock.unlock()
            } catch {
                log.error("sample capture failed: \(error.localizedDescription, privacy: .public)")
                resetHandling()
                return
            }
        }

        launcher.launchHelper(parentPid: pid, samplePath: samplePath) { [weak self] in
            self?.resetHandling()
        }
    }

    private func resetHandling() {
        lock.lock()
        isHandling = false
        lock.unlock()
    }
}
