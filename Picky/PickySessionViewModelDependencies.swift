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

enum PickyHUDSessionCardRequestAction: Equatable {
    case open
    case close
}

struct PickyHUDOpenSessionRequest: Equatable {
    let id: UUID
    let sessionID: String
    /// When set, only the HUD panel on this display should update the card.
    /// `nil` keeps the legacy behavior of updating every display.
    let targetDisplayID: CGDirectDisplayID?
    let action: PickyHUDSessionCardRequestAction

    init(
        id: UUID = UUID(),
        sessionID: String,
        targetDisplayID: CGDirectDisplayID?,
        action: PickyHUDSessionCardRequestAction = .open
    ) {
        self.id = id
        self.sessionID = sessionID
        self.targetDisplayID = targetDisplayID
        self.action = action
    }
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
@MainActor
protocol PickyDockLayoutStoring {
    func load() -> PickyDockLayout
    /// Synchronously admits a UI mutation into its FIFO persistence boundary.
    /// Completion reports the eventual worker result on the main actor.
    func enqueueSave(
        _ layout: PickyDockLayout,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    )
    /// Returns only after a durable write has completed.
    func saveDurably(_ layout: PickyDockLayout) async throws
}

extension PickyDockLayoutStoring {
    func saveDurably(_ layout: PickyDockLayout) async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueueSave(layout) { continuation.resume(with: $0) }
        }
    }
}

@MainActor
struct PickyNoopDockLayoutStore: PickyDockLayoutStoring {
    nonisolated init() {}

    func load() -> PickyDockLayout { .empty }
    func enqueueSave(
        _ layout: PickyDockLayout,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        completion(.success(()))
    }
}

@MainActor
struct PickySettingsDockLayoutStore: PickyDockLayoutStoring {
    var settingsStore: PickySettingsStore = PickySettingsStore()

    private var persistence: PickySettingsPersistenceCoordinator {
        .shared(for: settingsStore)
    }

    func load() -> PickyDockLayout {
        settingsStore.load().dockLayout
    }

    func enqueueSave(
        _ layout: PickyDockLayout,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        persistence.enqueue(
            mutation: { $0.dockLayout = layout },
            completion: { result in completion(result.map { _ in () }) }
        )
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
