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
    private static var pendingCancellationURL: URL?

    @discardableResult
    static func scheduleRelaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        delay: TimeInterval = 0.45,
        parentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        cancellationURL: URL? = nil,
        processRunner: (Process) throws -> Void = { try $0.run() }
    ) -> Bool {
        cancelPendingRelaunch()
        let cancellationURL = cancellationURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-relaunch-\(parentPID)-\(UUID().uuidString).cancel")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            relaunchShellCommand(
                bundlePath: bundleURL.path,
                delay: delay,
                parentPID: parentPID,
                cancellationPath: cancellationURL.path
            )
        ]
        do {
            try processRunner(task)
            pendingCancellationURL = cancellationURL
            return true
        } catch {
            print("⚠️ Picky relaunch scheduling failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func relaunchAndTerminate(
        bundleURL: URL = Bundle.main.bundleURL,
        processRunner: (Process) throws -> Void = { try $0.run() },
        terminate: () -> Void = { NSApp.terminate(nil) }
    ) -> Bool {
        guard scheduleRelaunch(bundleURL: bundleURL, processRunner: processRunner) else {
            return false
        }
        terminate()
        return true
    }

    /// Prevent a helper created for a rejected termination request from
    /// relaunching the app after some later, unrelated exit.
    static func cancelPendingRelaunch(fileManager: FileManager = .default) {
        guard let cancellationURL = pendingCancellationURL else { return }
        _ = fileManager.createFile(atPath: cancellationURL.path, contents: Data())
        pendingCancellationURL = nil
    }

    /// Wait for the current process to exit before opening the replacement.
    /// A cancellation marker is checked both before the PID probe and again
    /// immediately before `open`, closing the race with a rejected quit.
    static func relaunchShellCommand(
        bundlePath: String,
        delay: TimeInterval,
        parentPID: Int32,
        cancellationPath: String? = nil
    ) -> String {
        let initialDelay = max(0, delay)
        let cancelPath = cancellationPath.map(shellQuoted)
        let cancelCheck = cancelPath.map { "if [ -e \($0) ]; then /bin/rm -f \($0); exit 0; fi; " } ?? ""
        let cleanup = cancelPath.map { "/bin/rm -f \($0); " } ?? ""
        return "sleep \(initialDelay); _picky_wait=0; while [ $_picky_wait -lt 100 ]; do \(cancelCheck)if ! /bin/kill -0 \(parentPID) 2>/dev/null; then \(cancelCheck)\(cleanup)/usr/bin/open \(shellQuoted(bundlePath)); exit 0; fi; _picky_wait=$((_picky_wait + 1)); sleep 0.1; done; \(cleanup)exit 0"
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
