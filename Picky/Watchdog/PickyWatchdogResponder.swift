//
//  PickyWatchdogResponder.swift
//  Picky
//
//  Decides what to do when the watchdog reports a main-thread spin: capture
//  a sample snapshot for post-hoc analysis and spawn a helper process that
//  shows the "Picky is not responding" dialog. Coalesces repeat triggers
//  while a previous spin handling pass is still in flight.
//

import Foundation
import os

final class PickyWatchdogResponder {
    /// Captures `/usr/bin/sample` output to disk. Returns the resulting file path.
    protocol SampleCapturing {
        func captureSpinSample(pid: Int32) throws -> URL
    }

    /// Launches the alert helper process and reports back when the helper exits.
    protocol HelperLaunching {
        func launchHelper(parentPid: Int32, samplePath: URL, completion: @escaping () -> Void)
    }

    private let pid: Int32
    private let capturer: SampleCapturing
    private let launcher: HelperLaunching
    private let log = Logger(subsystem: "com.jonghakseo.picky", category: "watchdog.responder")

    private let lock = NSLock()
    private var isHandling = false

    init(pid: Int32, capturer: SampleCapturing, launcher: HelperLaunching) {
        self.pid = pid
        self.capturer = capturer
        self.launcher = launcher
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

        let samplePath: URL
        do {
            samplePath = try capturer.captureSpinSample(pid: pid)
        } catch {
            log.error("sample capture failed: \(error.localizedDescription, privacy: .public)")
            resetHandling()
            return
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
