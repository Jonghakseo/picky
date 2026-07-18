//
//  PickySessionViewModelDependencies.swift
//  Picky
//
//  Facade-facing value types and adapters used by PickySessionListViewModel.
//  Stateful session orchestration remains owned by the view model.
//

import AppKit
import Combine
import Foundation

protocol PickyNotificationDelivering: AnyObject {
    func deliver(title: String, body: String, identifier: String)
}

struct PickyHUDOpenSessionRequest: Equatable {
    let id = UUID()
    let sessionID: String
    /// When set, only the HUD panel on this display should open the card.
    /// `nil` keeps the legacy behavior of opening on every display.
    var targetDisplayID: CGDirectDisplayID?
}

enum PickyAutocompleteClientEvent: Equatable {
    case reconnected
    case resourcesReloaded(sessionID: String)
    case capabilities(PickyAutocompleteCapabilitiesSnapshot)
    case suggestions(PickyAutocompleteSuggestionsSnapshot)
    case completion(PickyAutocompleteCompletionApplied)
}

enum PickySessionListViewModelError: LocalizedError, Equatable {
    case emptyFollowUp
    case noSessionSelected
    case archivedSession
    case pickleRuntimeUnavailable
    case missingReport
    case missingPiSessionFile

    var errorDescription: String? {
        switch self {
        case .emptyFollowUp: "Steer message cannot be empty"
        case .noSessionSelected: "No session selected for steering"
        case .archivedSession: "Cannot steer an archived Pickle session"
        case .pickleRuntimeUnavailable: "Pickle runtime is unavailable"
        case .missingReport: "Report is not available yet"
        case .missingPiSessionFile: "Pi session file is not available yet"
        }
    }
}

protocol PickyClipboardWriting {
    func copy(_ text: String)
}

struct PickyPasteboardClipboardWriter: PickyClipboardWriting {
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Read/write access to the persisted dock layout (groups + ordered
/// session/group refs). Production uses the same `settings.json` Picky has
/// always used; tests inject a fake implementation.
protocol PickyDockLayoutStoring {
    func load() -> PickyDockLayout
    func save(_ layout: PickyDockLayout) throws
}

struct PickyNoopDockLayoutStore: PickyDockLayoutStoring {
    func load() -> PickyDockLayout { .empty }
    func save(_ layout: PickyDockLayout) throws {}
}

struct PickySettingsDockLayoutStore: PickyDockLayoutStoring {
    var settingsStore: PickySettingsStore = PickySettingsStore()

    func load() -> PickyDockLayout {
        settingsStore.load().dockLayout
    }

    func save(_ layout: PickyDockLayout) throws {
        var settings = settingsStore.load()
        settings.dockLayout = layout
        try settingsStore.save(settings)
    }
}

/// Owns the "which Pickle is the cursor hovering over for voice follow-up"
/// flag in its own ObservableObject so the SwiftUI subscription is scoped to
/// the one view that actually reads it (the conversation header's pi-badge).
/// When this flag lived on `PickySessionListViewModel.@Published` directly,
/// every conversation subview observing the viewModel re-evaluated its body
/// on every cursor enter/exit of the card, which cascaded into per-bubble
/// markdown re-parsing and TextKit re-measurement and showed up as visible
/// hover lag.
@MainActor
final class PickyVoiceFollowUpHoverState: ObservableObject {
    @Published var sessionID: String?
}
