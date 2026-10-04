//
//  CompanionManager+GlobalShortcuts.swift
//  Picky
//

import Combine

extension CompanionManager {
    /// Pushes all persisted global shortcuts into the shared arbiter. Called
    /// on launch and whenever Settings saves.
    func applyShortcutSpecsFromSettings(
        _ settings: PickySettings = PickySettingsStore().load()
    ) {
        globalShortcutArbiter.pushToTalkSpec = settings.pushToTalkShortcut
        globalShortcutArbiter.quickInputSpec = settings.quickInputShortcut
        globalShortcutArbiter.focusPickleSpec = settings.focusPickleShortcut
        globalPushToTalkShortcutMonitor.currentShortcutSpec = settings.pushToTalkShortcut
        print("⌨️  Shortcuts applied — PTT: \(settings.pushToTalkShortcut), QuickInput: \(settings.quickInputShortcut), Focus: \(settings.focusPickleShortcut)")
    }

    func bindFocusPickleShortcut() {
        focusPickleShortcutCancellable = globalShortcutArbiter.focusPicklePublisher
            .sink { [weak self] event in
                self?.onFocusPickleShortcut(event.mouseLocation)
            }
    }
}
