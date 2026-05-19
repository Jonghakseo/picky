//
//  ShellCommandMenuController.swift
//  Picky
//
//  AppKit glue that opens an NSAlert summarising the current install state of the
//  picky CLI shell wrapper and routes the user's choice to ShellCommandInstaller.
//
//  Picky is an LSUIElement app whose panels never activate the macOS menu bar, so
//  this controller is invoked from a SwiftUI button inside the companion panel
//  Settings tab rather than from a top-level menu item.
//

import AppKit
import Foundation

extension Notification.Name {
    /// Broadcast after the user installs or uninstalls the `/usr/local/bin/picky`
    /// wrapper through Settings, so live views (e.g. the stale wrapper banner
    /// in the companion status tab) can refresh `ShellCommandInstaller.currentStatus`
    /// without restarting the panel.
    static let pickyShellCommandStatusDidChange = Notification.Name("pickyShellCommandStatusDidChange")
}

@MainActor
final class ShellCommandMenuController: NSObject {
    static let shared = ShellCommandMenuController()

    /// Same on-disk settings file the rest of the app uses, so flipping the
    /// auto-install opt-out flag from here is picked up by
    /// `autoInstallShellCommandIfPermitted()` on the next launch.
    private let settingsStore: PickySettingsStore

    private override init() {
        self.settingsStore = PickySettingsStore()
        super.init()
    }

    /// Test-only initializer so we can verify the install/uninstall flow
    /// updates the persisted opt-out flag without touching the user's real
    /// settings file.
    init(settingsStore: PickySettingsStore) {
        self.settingsStore = settingsStore
        super.init()
    }

    func showInstallerAlert(
        bundleURL: URL = Bundle.main.bundleURL,
        installPath: URL = ShellCommandInstaller.defaultInstallPath
    ) {
        let status = ShellCommandInstaller.currentStatus(installPath: installPath, bundleURL: bundleURL)
        let alert = NSAlert()
        alert.messageText = "Install \(installPath.lastPathComponent) shell command"

        switch status {
        case .notInstalled:
            alert.informativeText = "Install a `\(installPath.lastPathComponent)` shell command at \(installPath.path) so terminals, Raycast, Hammerspoon, and cron can talk to Picky."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                runInstall(bundleURL: bundleURL, installPath: installPath)
            default: return
            }
        case .installedCurrent(let path):
            alert.informativeText = "`\(installPath.lastPathComponent)` is already installed at \(path.path) and points at this Picky.app."
            alert.addButton(withTitle: "Reinstall")
            alert.addButton(withTitle: "Uninstall")
            alert.addButton(withTitle: "Done")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                runInstall(bundleURL: bundleURL, installPath: installPath)
            case .alertSecondButtonReturn:
                runUninstall(installPath: installPath)
            default: return
            }
        case .installedStale(let path, let pinned):
            alert.informativeText = "`\(installPath.lastPathComponent)` is installed at \(path.path) but points at a different Picky.app:\n\(pinned)\n\nReinstall to point it at the running Picky.app, or uninstall."
            alert.addButton(withTitle: "Reinstall")
            alert.addButton(withTitle: "Uninstall")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                runInstall(bundleURL: bundleURL, installPath: installPath)
            case .alertSecondButtonReturn:
                runUninstall(installPath: installPath)
            default: return
            }
        case .foreign(let path):
            alert.informativeText = "A non-Picky file already exists at \(path.path). Picky will not overwrite it; please remove or rename it manually if you want to install the picky CLI here."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func runInstall(bundleURL: URL, installPath: URL) {
        do {
            let installed = try ShellCommandInstaller.install(bundleURL: bundleURL, installPath: installPath)
            // The user has explicitly asked for the command back — clear the
            // opt-out so a future move/reinstall of Picky.app can also be
            // handled silently on launch.
            setAutoInstallOptedOut(false)
            NotificationCenter.default.post(name: .pickyShellCommandStatusDidChange, object: nil)
            showInfo("Installed `\(installPath.lastPathComponent)` at \(installed.path).\n\nIf this is the first install, restart your terminal so the new command is on PATH.")
        } catch {
            showError("Install failed", error: error)
        }
    }

    private func runUninstall(installPath: URL) {
        do {
            try ShellCommandInstaller.uninstall(installPath: installPath)
            // Remember the user removed the command on purpose so the
            // launch-time auto-installer does not silently re-add it.
            setAutoInstallOptedOut(true)
            NotificationCenter.default.post(name: .pickyShellCommandStatusDidChange, object: nil)
            showInfo("Removed `\(installPath.lastPathComponent)` from \(installPath.path).")
        } catch {
            showError("Uninstall failed", error: error)
        }
    }

    private func setAutoInstallOptedOut(_ value: Bool) {
        var settings = settingsStore.load()
        guard settings.shellCommandAutoInstallOptedOut != value else { return }
        settings.shellCommandAutoInstallOptedOut = value
        do {
            try settingsStore.save(settings)
            NotificationCenter.default.post(name: .pickySettingsDidSave, object: nil)
        } catch {
            // Opt-out state is non-critical — the user can always re-flip it
            // from Settings. Don't surface a transient disk failure as an
            // alert; just log it so debug builds can spot a regression.
            print("⚠️ Picky: failed to persist shell command opt-out flag: \(error)")
        }
    }

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Picky CLI"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
