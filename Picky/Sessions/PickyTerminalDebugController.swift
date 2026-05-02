//
//  PickyTerminalDebugController.swift
//  Picky
//
//  Terminal-only launch mode for rapidly iterating on Pi terminal rendering.
//

import AppKit
import Foundation

struct PickyTerminalDebugConfiguration: Equatable {
    let sessionFilePath: String
    let cwd: String?
    let title: String

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> PickyTerminalDebugConfiguration? {
        guard let rawSessionFilePath = environment["PICKY_TERMINAL_DEBUG_SESSION"]?.nonEmptyTrimmed else { return nil }
        return PickyTerminalDebugConfiguration(
            sessionFilePath: NSString(string: rawSessionFilePath).expandingTildeInPath,
            cwd: environment["PICKY_TERMINAL_DEBUG_CWD"]?.nonEmptyTrimmed.map { NSString(string: $0).expandingTildeInPath },
            title: environment["PICKY_TERMINAL_DEBUG_TITLE"]?.nonEmptyTrimmed ?? "Pi terminal debug"
        )
    }
}

@MainActor
final class PickyTerminalDebugController {
    private let configuration: PickyTerminalDebugConfiguration
    private var didStart = false

    init(configuration: PickyTerminalDebugConfiguration) {
        self.configuration = configuration
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        print("🧪 Picky terminal debug mode")
        print("🧪 Session: \(configuration.sessionFilePath)")
        print("🧪 CWD: \(configuration.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)")

        guard FileManager.default.fileExists(atPath: configuration.sessionFilePath) else {
            print("❌ Picky terminal debug session does not exist: \(configuration.sessionFilePath)")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        do {
            try PickyTerminalOverlayPresenter.shared.openTerminal(
                sessionID: "terminal-debug",
                title: configuration.title,
                sessionFilePath: configuration.sessionFilePath,
                cwd: configuration.cwd,
                onClose: {
                    NSApp.terminate(nil)
                }
            )
        } catch {
            print("❌ Failed to open Picky terminal debug mode: \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    func stop() {}
}
