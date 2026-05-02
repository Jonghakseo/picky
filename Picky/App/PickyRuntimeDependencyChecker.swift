//
//  PickyRuntimeDependencyChecker.swift
//  Picky
//

import Foundation

enum PickyFriendlyRuntimeError: LocalizedError, Equatable {
    case missingDaemon(path: String)
    case missingPiSDK(path: String)
    case missingPiExecutable
    case daemonCrashed(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .missingDaemon(let path): "picky-agentd is not available at \(path). Rebuild the daemon or check Settings → Daemon."
        case .missingPiSDK(let path): "Pi SDK is not available at \(path). Install or update local Pi before starting sessions."
        case .missingPiExecutable: "The pi executable was not found in PATH. Install Pi or add it to PATH, then restart Picky."
        case .daemonCrashed(let detail): "picky-agentd stopped unexpectedly. Open logs for details. \(detail)"
        case .permissionDenied(let permission): "Picky does not have \(permission) permission. Grant it in macOS Settings; the task can continue with reduced context."
        }
    }
}

struct PickyRuntimeDependencyChecker {
    var fileManager: FileManager = .default
    var piSDKPath: String = "/usr/local/lib/node_modules/@mariozechner/pi-coding-agent"
    var pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? ""

    func missingPiSDKErrorIfNeeded() -> PickyFriendlyRuntimeError? {
        fileManager.fileExists(atPath: piSDKPath) ? nil : .missingPiSDK(path: piSDKPath)
    }

    func missingPiExecutableErrorIfNeeded() -> PickyFriendlyRuntimeError? {
        for directory in pathEnvironment.split(separator: ":").map(String.init) {
            if fileManager.isExecutableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent("pi").path) { return nil }
        }
        return .missingPiExecutable
    }
}
