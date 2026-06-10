//
//  CompanionPanelSettingsModel.swift
//  Picky
//
//  Navigation sections/routes, grouping, and save-status models backing the
//  companion panel settings surface.
//

import SwiftUI

enum CompanionPanelSettingsSection: CaseIterable, Hashable {
    case general
    case oauth
    case mainAgent
    case pickle
    case overlayAndNotifications
    case voice
    case shortcuts
    case builtinTools
    case onboarding
}

/// One screen of the Settings tab. The index screen lists the categories;
/// every other case is a leaf page hosting that category's content. Adding a
/// new category amounts to: extend this enum, add a label/subtitle, and route
/// to the matching helper view inside CompanionPanelSettingsView.
enum CompanionPanelSettingsRoute: Hashable {
    case index
    case general
    case oauth
    case mainAgent
    case pickle
    /// Combined page that used to live as two separate routes (`.cursorBubbles`
    /// and `.notification`). Old `picky://` URLs still resolve here through
    /// `PickyDeepLink.fromDeepLinkPath` aliases.
    case overlayAndNotifications
    case voice
    case shortcuts
    case builtinTools
    case onboarding

    var section: CompanionPanelSettingsSection? {
        switch self {
        case .index: nil
        case .general: .general
        case .oauth: .oauth
        case .mainAgent: .mainAgent
        case .pickle: .pickle
        case .overlayAndNotifications: .overlayAndNotifications
        case .voice: .voice
        case .shortcuts: .shortcuts
        case .builtinTools: .builtinTools
        case .onboarding: .onboarding
        }
    }

    /// Localized title for the route. Resolved through `L10n.t(_:)` rather
    /// than `Text(...)` because callers store the string in `String` fields
    /// (navigation breadcrumbs, button labels) and we want a value, not a view.
    var title: String {
        switch self {
        case .index: L10n.t("settings.indexTitle")
        case .general: L10n.t("settings.general.title")
        case .oauth: L10n.t("settings.oauth.title")
        case .mainAgent: L10n.t("settings.section.picky.title")
        case .pickle: L10n.t("settings.section.pickle.title")
        case .overlayAndNotifications: L10n.t("settings.section.overlayAndNotifications.title")
        case .voice: L10n.t("settings.section.voice.title")
        case .shortcuts: L10n.t("settings.section.shortcuts.title")
        case .builtinTools: L10n.t("settings.section.builtinTools.title")
        case .onboarding: L10n.t("settings.section.onboarding.title")
        }
    }

    var subtitle: String? {
        switch self {
        case .index: nil
        case .general: L10n.t("settings.general.subtitle.index")
        case .oauth: L10n.t("settings.oauth.subtitle.index")
        case .mainAgent: L10n.t("settings.section.picky.subtitle")
        case .pickle: L10n.t("settings.section.pickle.subtitle")
        case .overlayAndNotifications: L10n.t("settings.section.overlayAndNotifications.subtitle")
        case .voice: L10n.t("settings.section.voice.subtitle")
        case .shortcuts: L10n.t("settings.section.shortcuts.subtitle")
        case .builtinTools: L10n.t("settings.section.builtinTools.subtitle")
        case .onboarding: L10n.t("settings.section.onboarding.subtitle")
        }
    }
}

/// Visual grouping for the Settings index. Each group renders as a small
/// uppercase header followed by its leaf rows. Order inside the file is the
/// order the user sees — rearrange here, not by editing the enum.
///
/// `.onboarding` is intentionally absent from every group. The route/section/
/// view still exist so the takeover overlay (later phases) can mark completion
/// through the same plumbing, and so dev builds can re-enable the Replay entry
/// with a single-line edit. Don't remove the case.
///
/// Feedback is not a Settings sub-page anymore — it renders as a panel-level
/// overlay reached from the Status tab’s entry row.
struct CompanionPanelSettingsGroup: Identifiable {
    let id: String
    let titleKey: LocalizedStringKey
    let routes: [CompanionPanelSettingsRoute]
}

let companionPanelSettingsGroups: [CompanionPanelSettingsGroup] = [
    CompanionPanelSettingsGroup(
        id: "general",
        titleKey: "settings.group.general.title",
        routes: [.general, .oauth, .shortcuts]
    ),
    CompanionPanelSettingsGroup(
        id: "agents",
        titleKey: "settings.group.agents.title",
        routes: [.mainAgent, .pickle, .builtinTools]
    ),
    CompanionPanelSettingsGroup(
        id: "surface",
        titleKey: "settings.group.surface.title",
        routes: [.voice, .overlayAndNotifications]
    )
]

/// Flat order of every user-visible route, derived from the groups. Kept as a
/// computed convenience for any caller that just needs to iterate every leaf.
private var companionPanelSettingsRouteOrder: [CompanionPanelSettingsRoute] {
    companionPanelSettingsGroups.flatMap(\.routes)
}

enum CompanionPanelSettingsSaveStatus: Equatable {
    case idle
    case saved
    case dirty
}

struct CompanionPanelSettingsSaveStatuses: Equatable {
    private var statuses: [CompanionPanelSettingsSection: CompanionPanelSettingsSaveStatus] = [:]

    subscript(_ section: CompanionPanelSettingsSection) -> CompanionPanelSettingsSaveStatus {
        statuses[section] ?? .idle
    }

    mutating func markSaved(_ section: CompanionPanelSettingsSection) {
        set(.saved, for: section)
    }

    mutating func markDirty(_ section: CompanionPanelSettingsSection) {
        set(.dirty, for: section)
    }

    mutating func clear(_ section: CompanionPanelSettingsSection) {
        set(.idle, for: section)
    }

    mutating func clearSaved(_ section: CompanionPanelSettingsSection) {
        if self[section] == .saved { clear(section) }
    }

    private mutating func set(_ status: CompanionPanelSettingsSaveStatus, for section: CompanionPanelSettingsSection) {
        if status == .idle {
            statuses.removeValue(forKey: section)
        } else {
            statuses[section] = status
        }
    }
}
