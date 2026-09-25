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
    private let persistence: PickySettingsPersistenceCoordinator

    private override init() {
        self.settingsStore = PickySettingsStore()
        self.persistence = .shared(for: settingsStore)
        super.init()
    }

    /// Test-only initializer so we can verify the install/uninstall flow
    /// updates the persisted opt-out flag without touching the user's real
    /// settings file.
    init(settingsStore: PickySettingsStore) {
        self.settingsStore = settingsStore
        self.persistence = .shared(for: settingsStore)
        super.init()
    }

    func showInstallerAlert(
        bundleURL: URL = Bundle.main.bundleURL,
        installPath: URL = ShellCommandInstaller.defaultInstallPath
    ) {
        let status = ShellCommandInstaller.currentStatus(installPath: installPath, bundleURL: bundleURL)
        let alert = NSAlert()
        alert.messageText = L10n.t("shellCommand.install.title", installPath.lastPathComponent)

        switch status {
        case .notInstalled:
            alert.informativeText = L10n.t("shellCommand.install.body", installPath.lastPathComponent, installPath.path)
            alert.addButton(withTitle: L10n.t("shellCommand.install"))
            alert.addButton(withTitle: L10n.t("common.cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                runInstall(bundleURL: bundleURL, installPath: installPath)
            default: return
            }
        case .installedCurrent(let path):
            alert.informativeText = L10n.t("shellCommand.current.body", installPath.lastPathComponent, path.path)
            alert.addButton(withTitle: L10n.t("shellCommand.reinstall"))
            alert.addButton(withTitle: L10n.t("shellCommand.uninstall"))
            alert.addButton(withTitle: L10n.t("shellCommand.done"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                runInstall(bundleURL: bundleURL, installPath: installPath)
            case .alertSecondButtonReturn:
                runUninstall(installPath: installPath)
            default: return
            }
        case .installedStale(let path, let pinned):
            alert.informativeText = L10n.t("shellCommand.stale.body", installPath.lastPathComponent, path.path, pinned)
            alert.addButton(withTitle: L10n.t("shellCommand.reinstall"))
            alert.addButton(withTitle: L10n.t("shellCommand.uninstall"))
            alert.addButton(withTitle: L10n.t("common.cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                runInstall(bundleURL: bundleURL, installPath: installPath)
            case .alertSecondButtonReturn:
                runUninstall(installPath: installPath)
            default: return
            }
        case .foreign(let path):
            alert.informativeText = L10n.t("shellCommand.conflict.body", path.path)
            alert.addButton(withTitle: L10n.t("shellCommand.ok"))
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
            showInfo(L10n.t("shellCommand.installed.body", installPath.lastPathComponent, installed.path))
        } catch {
            showError(L10n.t("shellCommand.installFailed"), error: error)
        }
    }

    private func runUninstall(installPath: URL) {
        do {
            try ShellCommandInstaller.uninstall(installPath: installPath)
            // Remember the user removed the command on purpose so the
            // launch-time auto-installer does not silently re-add it.
            setAutoInstallOptedOut(true)
            NotificationCenter.default.post(name: .pickyShellCommandStatusDidChange, object: nil)
            showInfo(L10n.t("shellCommand.removed.body", installPath.lastPathComponent, installPath.path))
        } catch {
            showError(L10n.t("shellCommand.uninstallFailed"), error: error)
        }
    }

    private func setAutoInstallOptedOut(_ value: Bool) {
        // Always admit the latest intent. Reading the file here can observe an
        // older value while a preceding install/uninstall write is still queued.
        persistence.enqueue(notification: .settingsDidSave) {
            $0.shellCommandAutoInstallOptedOut = value
        }
    }

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Picky CLI"
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("shellCommand.ok"))
        alert.runModal()
    }

    private func showError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("shellCommand.ok"))
        alert.runModal()
    }
}
