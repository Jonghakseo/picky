//
//  PickyNotificationPreferencesStore.swift
//  Picky
//
//  Provides the live `PickyNotificationPreferences` snapshot to runtime
//  components (notably PickySessionListViewModel) that decide whether to
//  deliver a macOS banner. Loads from PickySettingsStore and refreshes
//  whenever the settings scene posts `.pickySettingsDidSave`.
//

import Foundation

/// Read-only contract for components that need to consult notification toggles.
/// Tests inject a stub conforming to this protocol so they can flip individual
/// toggles without touching disk-backed settings.
protocol PickyNotificationPreferencesProviding: AnyObject {
    var notificationPreferences: PickyNotificationPreferences { get }
}

/// Loads the notification toggles from disk on init and refreshes them whenever
/// the settings scene posts `.pickySettingsDidSave`. Not marked `@MainActor` so
/// it can be used as a default-argument value in `PickySessionListViewModel.init`,
/// which is itself a main-actor-isolated init that ignores actor isolation in
/// default-arg evaluation. The notification observer is bound to `.main`, so the
/// stored property is only ever read/written on the main thread in practice.
final class PickyNotificationPreferencesStore: PickyNotificationPreferencesProviding {
    private let settingsStore: PickySettingsStore
    private(set) var notificationPreferences: PickyNotificationPreferences
    private var observer: NSObjectProtocol?

    init(settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.settingsStore = settingsStore
        self.notificationPreferences = settingsStore.load().notifications
        observer = NotificationCenter.default.addObserver(
            forName: .pickySettingsDidSave,
            object: nil,
            queue: .main
        ) { [weak self, settingsStore] _ in
            self?.notificationPreferences = settingsStore.load().notifications
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Stub used by unit tests; mutate `notificationPreferences` directly to flip toggles
/// between event injections.
final class PickyStubNotificationPreferences: PickyNotificationPreferencesProviding {
    var notificationPreferences: PickyNotificationPreferences

    init(notificationPreferences: PickyNotificationPreferences = .defaults) {
        self.notificationPreferences = notificationPreferences
    }
}
