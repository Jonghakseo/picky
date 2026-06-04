//
//  PickyRelauncher.swift
//  Picky
//
//  Schedules a fresh launch of the current .app from a tiny external shell
//  process, then lets the caller terminate the current process. The delay is
//  intentional: `open` should run after AppKit has had time to tear down the
//  existing menu bar app instance.
//

import AppKit
import Foundation

enum PickyRelauncher {
    @discardableResult
    static func scheduleRelaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        delay: TimeInterval = 0.45,
        processRunner: (Process) throws -> Void = { try $0.run() }
    ) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "sleep \(max(0, delay)); /usr/bin/open \(shellQuoted(bundleURL.path))"
        ]
        do {
            try processRunner(task)
            return true
        } catch {
            print("⚠️ Picky relaunch scheduling failed: \(error.localizedDescription)")
            return false
        }
    }

    static func relaunchAndTerminate(
        bundleURL: URL = Bundle.main.bundleURL,
        terminate: () -> Void = { NSApp.terminate(nil) }
    ) {
        _ = scheduleRelaunch(bundleURL: bundleURL)
        terminate()
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
