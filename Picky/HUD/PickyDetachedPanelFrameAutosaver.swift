//
//  PickyDetachedPanelFrameAutosaver.swift
//  Picky
//
//  Per-panel-kind frame persistence for Picky's detached AppKit panels
//  (markdown report viewer, tool history viewer, Pi terminal overlay).
//
//  AppKit's `setFrameAutosaveName(_:)` is single-instance: when several
//  panels of the same kind coexist (e.g. one report viewer per opened
//  message), only the first window claims the slot and every subsequent
//  panel's move/resize is silently dropped. This file reads/writes the
//  frame through `PickySettingsStore` so the most recently moved panel
//  always wins, regardless of how many panels share the same kind.
//

import AppKit
import Foundation

/// Identifies which kind of detached panel a saved frame belongs to. The raw
/// value is what gets persisted as the dictionary key inside `PickySettings.detachedPanelFrames`,
/// so renaming a case here changes the on-disk format. The values intentionally
/// match the legacy `setFrameAutosaveName(_:)` strings so the one-shot legacy
/// migration in `PickyDetachedPanelFramePersister` reads cleanly from
/// `UserDefaults` without an extra mapping table.
enum PickyDetachedPanelKind: String {
    case reportViewer = "PickyReportViewer"
    case toolHistoryViewer = "PickyToolHistoryViewer"
    case terminalOverlay = "PickyTerminalOverlay"
    case diffViewer = "PickyDiffViewer"
}

/// Window-scoped persistence hook for a single detached panel's frame.
/// Mirrors the `*FontScalePersister` pattern used elsewhere in the file so
/// tests can inject deterministic load/save closures without touching disk.
@MainActor
struct PickyDetachedPanelFramePersister {
    let load: () -> CGRect?
    let save: (CGRect) -> Void

    /// Live persister backed by `PickySettingsStore`. The closures intentionally
    /// re-read settings on every save to avoid blowing away other concurrent
    /// settings edits (e.g. dock side, font scale) that may have happened
    /// between when this persister was constructed and when the user moved
    /// the panel.
    ///
    /// `legacyDefaults` is the source for the one-shot migration from the previous
    /// `setFrameAutosaveName(_:)` entry — pass `nil` from tests so the developer's
    /// actual `UserDefaults` doesn't bleed into a test that expects an empty store.
    static func backed(
        by settingsStore: PickySettingsStore,
        kind: PickyDetachedPanelKind,
        legacyDefaults: UserDefaults? = .standard
    ) -> PickyDetachedPanelFramePersister {
        let key = kind.rawValue
        return PickyDetachedPanelFramePersister(
            load: {
                if let stored = settingsStore.load().detachedPanelFrames[key] {
                    return stored.cgRect
                }
                // One-shot migration so users with a remembered position don't get
                // bounced back to `targetFrame()` after upgrading.
                if let legacyDefaults,
                   let raw = legacyDefaults.string(forKey: "NSWindow Frame \(key)"),
                   let legacy = PickyDetachedPanelFrame.parseLegacyAutosave(raw) {
                    return legacy.cgRect
                }
                return nil
            },
            save: { rect in
                var current = settingsStore.load()
                current.detachedPanelFrames[key] = PickyDetachedPanelFrame(rect)
                try? settingsStore.save(current)
            }
        )
    }

    /// No-op persister for unit tests and previews.
    static let noop = PickyDetachedPanelFramePersister(
        load: { nil },
        save: { _ in }
    )
}

/// Restores a panel's saved frame on creation and writes the latest frame
/// back to the persister whenever the user moves or resizes the panel.
/// Hold a strong reference to the autosaver for the panel's lifetime so the
/// notification observers stay alive — the autosaver does not retain the
/// panel itself, so dropping the autosaver tears down the observation.
@MainActor
final class PickyDetachedPanelFrameAutosaver {
    private weak var panel: NSWindow?
    private let persister: PickyDetachedPanelFramePersister
    private var observers: [NSObjectProtocol] = []

    init(panel: NSWindow, persister: PickyDetachedPanelFramePersister) {
        self.panel = panel
        self.persister = persister

        if let saved = persister.load() {
            // `constrainFrameRect` clamps to the closest visible screen so a
            // frame saved on a now-disconnected monitor doesn't leave the
            // panel off-screen.
            let safe = panel.constrainFrameRect(saved, to: nil)
            panel.setFrame(safe, display: false)
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistCurrentFrame() }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistCurrentFrame() }
        })
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    private func persistCurrentFrame() {
        guard let panel else { return }
        persister.save(panel.frame)
    }
}
