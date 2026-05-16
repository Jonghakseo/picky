//
//  PickyRuntimeDependencyChecker.swift
//  Picky
//

import Foundation

enum PickyFriendlyRuntimeError: LocalizedError, Equatable {
    case missingPiExecutable
    case daemonCrashed(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .missingPiExecutable: "The pi executable was not found in PATH. Install Pi or add it to PATH, then restart Picky."
        case .daemonCrashed(let detail): "picky-agentd stopped unexpectedly. Open logs for details. \(detail)"
        case .permissionDenied(let permission): "Picky does not have \(permission) permission. Grant it in macOS Settings; the task can continue with reduced context."
        }
    }
}

/// "Is Pi installed?" boils down to "is `pi` discoverable as an executable?".
/// The SDK ships bundled inside `Picky.app/Contents/Resources/agentd/node_modules`
/// so Picky itself does not depend on the user's global SDK install location;
/// what matters is that the user has a `pi` binary they (or Picky's terminal
/// resume command) can launch. Pi can be installed via npm into a wide range of
/// prefixes (Homebrew, asdf, nvm, npm global, …), so probing specific package
/// scope directories is fragile. Instead we follow the same rule a shell would:
/// search `PATH` (plus a small set of well-known fallbacks for app launches
/// that inherit a stripped-down PATH from Launch Services).
struct PickyRuntimeDependencyChecker {
    var fileManager: FileManager = .default
    var pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    /// macOS apps started via Launch Services often see only `/usr/bin:/bin:
    /// /usr/sbin:/sbin`, dropping user-shell entries like `/usr/local/bin`,
    /// `/opt/homebrew/bin`, and `~/.pi/agent/bin`. We probe those after the
    /// inherited PATH so a globally-installed Pi is still discoverable when
    /// the user double-clicks Picky.app instead of launching from a terminal.
    var additionalProbePaths: [String] = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        NSString(string: "~/.pi/agent/bin").expandingTildeInPath
    ]
    /// When true, the executable check pretends Pi is missing regardless of
    /// what the filesystem actually reports. Set via `PICKY_FORCE_PI_MISSING=1`
    /// from the shell or Xcode scheme so we can exercise the "Pi not installed"
    /// UI (and the onboarding gate) without uninstalling the user's global Pi.
    /// Mirrors the existing `PICKY_AGENTD_RUNTIME=mock` developer override.
    var forceMissing: Bool = ProcessInfo.processInfo.environment["PICKY_FORCE_PI_MISSING"] == "1"

    func missingPiExecutableErrorIfNeeded() -> PickyFriendlyRuntimeError? {
        if forceMissing { return .missingPiExecutable }
        let inherited = pathEnvironment.split(separator: ":").map(String.init)
        let candidates = inherited + additionalProbePaths
        for directory in candidates where !directory.isEmpty {
            let piPath = URL(fileURLWithPath: directory).appendingPathComponent("pi").path
            if fileManager.isExecutableFile(atPath: piPath) { return nil }
        }
        return .missingPiExecutable
    }
}
