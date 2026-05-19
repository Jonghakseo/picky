//
//  PickyWatchdogHelperLauncher.swift
//  Picky
//
//  Spawns the bundled `picky-watchdog-alert` helper so the recovery dialog
//  can appear even when the main process can no longer drive its own UI.
//  Bridges `PickyWatchdogResponder.HelperLaunching` to a real `Process`.
//

import Foundation
import os

struct PickyWatchdogHelperLauncher: PickyWatchdogResponder.HelperLaunching {
    /// Path to the helper executable inside `Picky.app/Contents/Helpers/`.
    /// Resolved at construction time so the spawn site doesn't need to know
    /// where the helper lives. Returns `nil` if the helper is missing — in
    /// dev builds without packaging the responder will fall back to logging.
    let helperPath: URL?

    private let log = Logger(subsystem: "com.jonghakseo.picky", category: "watchdog.helper")

    /// Default initializer points at the bundled helper. Tests can pass an
    /// explicit URL.
    init(helperPath: URL? = PickyWatchdogHelperLauncher.bundledHelperURL()) {
        self.helperPath = helperPath
    }

    static func bundledHelperURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/picky-watchdog-alert")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func launchHelper(parentPid: Int32, samplePath: URL, completion: @escaping () -> Void) {
        guard let helperPath else {
            log.error("watchdog helper executable missing — skipping recovery dialog")
            completion()
            return
        }
        let process = Process()
        process.executableURL = helperPath
        process.arguments = [
            "--parent-pid", String(parentPid),
            "--sample-path", samplePath.path,
        ]
        process.terminationHandler = { _ in
            // Reset responder state on the main queue so subsequent spin
            // detections can fire again.
            DispatchQueue.main.async { completion() }
        }
        do {
            try process.run()
            log.notice("spawned watchdog helper pid=\(process.processIdentifier, privacy: .public)")
        } catch {
            log.error("failed to spawn watchdog helper: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { completion() }
        }
    }
}
