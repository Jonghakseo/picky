//
//  PickySessionUtilityUIStateStore.swift
//  Picky
//
//  Persisted per-session selection and artifact-read state for the HUD utility panel.
//

import Combine
import Foundation

@MainActor
final class PickySessionUtilityUIStateStore: ObservableObject {
    static let shared = PickySessionUtilityUIStateStore()
    static let storageKey = "pickyHUD.utilityPanel.sessionState"

    private struct Record: Codable, Equatable {
        var selectedTabRawValue: String
        var lastSeenArtifactsAt: Date?
    }

    private let defaults: UserDefaults
    private var records: [String: Record]
    @Published private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = Self.loadRecords(from: defaults)
    }

    func selectedTab(for sessionID: String) -> PickyHUDUtilityPanelTab {
        guard let rawValue = records[sessionID]?.selectedTabRawValue else { return .terminal }
        if rawValue == "activity" { return .progress }
        return PickyHUDUtilityPanelTab(rawValue: rawValue) ?? .terminal
    }

    func select(_ tab: PickyHUDUtilityPanelTab, for sessionID: String) {
        var record = records[sessionID] ?? Record(selectedTabRawValue: PickyHUDUtilityPanelTab.terminal.rawValue, lastSeenArtifactsAt: nil)
        guard record.selectedTabRawValue != tab.rawValue else { return }
        record.selectedTabRawValue = tab.rawValue
        records[sessionID] = record
        persist()
    }

    func lastSeenArtifactsAt(for sessionID: String) -> Date? {
        records[sessionID]?.lastSeenArtifactsAt
    }

    /// Marking happens only for the visible artifact tab, so opening another tab never
    /// clears the artifact badge accidentally.
    func markArtifactsSeen(
        for sessionID: String,
        at date: Date?,
        isArtifactsTabSelected: Bool,
        isHUDPanelVisible: Bool
    ) {
        guard isArtifactsTabSelected, isHUDPanelVisible, let date else { return }
        var record = records[sessionID] ?? Record(selectedTabRawValue: PickyHUDUtilityPanelTab.artifacts.rawValue, lastSeenArtifactsAt: nil)
        guard record.lastSeenArtifactsAt.map({ $0 < date }) ?? true else { return }
        record.lastSeenArtifactsAt = date
        records[sessionID] = record
        persist()
    }

    func remove(sessionID: String) {
        guard records.removeValue(forKey: sessionID) != nil else { return }
        persist()
    }

    func removeAll(except sessionIDs: Set<String>) {
        let next = records.filter { sessionIDs.contains($0.key) }
        guard next != records else { return }
        records = next
        persist()
    }

    private func persist() {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.storageKey)
        }
        revision &+= 1
    }

    private static func loadRecords(from defaults: UserDefaults) -> [String: Record] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return records
    }
}
