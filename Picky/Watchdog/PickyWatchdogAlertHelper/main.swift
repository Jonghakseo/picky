//
//  picky-watchdog-alert — main.swift
//
//  Small executable bundled inside Picky.app/Contents/Helpers/. Invoked by
//  PickyWatchdogResponder when the main process is unresponsive. Shows a
//  modal NSAlert (since the parent app can no longer drive its own UI) and,
//  on user confirmation, kills the parent and relaunches the .app.
//
//  Usage:
//    picky-watchdog-alert --parent-pid <pid> --sample-path <path>
//

import AppKit
import Darwin
import Foundation

// MARK: - Argument parsing

private func parseArgs() -> (parentPid: pid_t, samplePath: String)? {
    var parentPid: pid_t?
    var samplePath: String?
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--parent-pid":
            if i + 1 < args.count, let value = pid_t(args[i + 1]) {
                parentPid = value
                i += 2
                continue
            }
        case "--sample-path":
            if i + 1 < args.count {
                samplePath = args[i + 1]
                i += 2
                continue
            }
        default:
            break
        }
        i += 1
    }
    guard let parentPid, let samplePath else { return nil }
    return (parentPid, samplePath)
}

// MARK: - Parent .app resolution

/// Resolves the parent Picky.app bundle URL. Tries the running-application
/// lookup first (works while the parent process still exists), then falls
/// back to the helper's own bundle path (`Picky.app/Contents/Helpers/...`).
private func resolveParentBundleURL(parentPid: pid_t) -> URL? {
    if let app = NSRunningApplication(processIdentifier: parentPid),
       let url = app.bundleURL {
        return url
    }
    let helperURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    // .../Picky.app/Contents/Helpers/picky-watchdog-alert
    //              -> Helpers -> Contents -> Picky.app
    let candidate = helperURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    if candidate.pathExtension == "app",
       FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }
    return nil
}

// MARK: - Alert UI

private enum AlertChoice {
    case restart
    case revealSample
    case ignore
}

private func loadParentAppIcon(bundleURL: URL?, parentPid: pid_t) -> NSImage? {
    if let bundleURL {
        let iconURL = bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
        if let image = NSImage(contentsOf: iconURL) {
            return image
        }
    }
    if let app = NSRunningApplication(processIdentifier: parentPid) {
        return app.icon
    }
    // Last-resort fallback for smoke tests: find any running app whose
    // bundle identifier looks like Picky.
    let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "com.jonghakseo.picky")
    if let icon = candidates.first?.icon { return icon }
    return nil
}

private func showAlert(samplePath: String, icon: NSImage?) -> AlertChoice {
    let alert = NSAlert()
    alert.alertStyle = .warning
    if let icon { alert.icon = icon }
    alert.messageText = "Picky is not responding"
    alert.informativeText = """
    The main thread was unresponsive for several seconds. A diagnostic sample was saved to:

    \(samplePath)

    Restarting Picky will recover the UI and restart the local agentd daemon. Persisted sessions will reconnect after launch.
    """
    alert.addButton(withTitle: "Restart Picky")
    alert.addButton(withTitle: "Reveal Sample in Finder")
    alert.addButton(withTitle: "Ignore")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .restart
    case .alertSecondButtonReturn: return .revealSample
    default: return .ignore
    }
}

// MARK: - Agentd cleanup

private func runProcess(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

private func childProcessIds(of parentPid: pid_t) -> [pid_t] {
    guard let output = runProcess("/usr/bin/pgrep", ["-P", String(parentPid)]) else { return [] }
    return output
        .split(whereSeparator: \.isNewline)
        .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

private func commandLine(for pid: pid_t) -> String {
    runProcess("/bin/ps", ["-p", String(pid), "-o", "command="])?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func isPickyAgentdCommand(_ command: String) -> Bool {
    let markers = [
        "/Contents/Resources/agentd/dist/index.js",
        "/Contents/Resources/agentd/",
        "/agentd/dist/index.js",
        "/agentd/src/index.ts",
        "picky-agentd",
    ]
    return markers.contains { command.contains($0) }
}

private func descendantProcessIds(of rootPid: pid_t) -> [pid_t] {
    var result: [pid_t] = []
    var queue = childProcessIds(of: rootPid)
    while !queue.isEmpty {
        let pid = queue.removeFirst()
        result.append(pid)
        queue.append(contentsOf: childProcessIds(of: pid))
    }
    return result
}

private func processExists(_ pid: pid_t) -> Bool {
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

private func terminateProcessTree(_ pids: [pid_t], graceMicroseconds: useconds_t = 1_000_000) {
    guard !pids.isEmpty else { return }
    for pid in pids where processExists(pid) {
        Darwin.kill(pid, SIGTERM)
    }

    let deadline = Date().addingTimeInterval(TimeInterval(graceMicroseconds) / 1_000_000)
    while Date() < deadline, pids.contains(where: processExists) {
        usleep(50_000)
    }

    for pid in pids where processExists(pid) {
        Darwin.kill(pid, SIGKILL)
    }
}

private func terminateAgentdChildren(of parentPid: pid_t) {
    let directChildren = childProcessIds(of: parentPid)
    let agentdRoots = directChildren.filter { isPickyAgentdCommand(commandLine(for: $0)) }
    guard !agentdRoots.isEmpty else { return }

    var victims: [pid_t] = []
    for root in agentdRoots {
        // Stop descendants before the daemon root so long-running Pi subprocesses
        // do not survive as orphans when the watchdog relaunches the app.
        victims.append(contentsOf: descendantProcessIds(of: root).reversed())
        victims.append(root)
    }
    var seen = Set<pid_t>()
    let uniqueVictims = victims.filter { seen.insert($0).inserted }
    terminateProcessTree(uniqueVictims)
}

// MARK: - Restart

private func restartParent(parentPid: pid_t, bundleURL: URL?) {
    terminateAgentdChildren(of: parentPid)
    kill(parentPid, SIGKILL)
    // Give launchd a beat to reap the dead process and release inherited ports.
    usleep(200_000)
    guard let bundleURL else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    let semaphore = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
}

// MARK: - Main

guard let parsed = parseArgs() else {
    FileHandle.standardError.write(Data(
        "usage: picky-watchdog-alert --parent-pid <pid> --sample-path <path>\n".utf8
    ))
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

let parentBundleURL = resolveParentBundleURL(parentPid: parsed.parentPid)
let parentIcon = loadParentAppIcon(bundleURL: parentBundleURL, parentPid: parsed.parentPid)

loop: while true {
    switch showAlert(samplePath: parsed.samplePath, icon: parentIcon) {
    case .restart:
        restartParent(parentPid: parsed.parentPid, bundleURL: parentBundleURL)
        break loop
    case .revealSample:
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: parsed.samplePath)])
        // Show the alert again so the user can still choose Restart or Ignore.
        continue
    case .ignore:
        break loop
    }
}

exit(0)
