//
//  PickySettingsCLIExposure.swift
//  Picky
//

import Foundation

enum PickySettingsCLIValueType: String, Equatable {
    case bool
    case string
    case `enum`
}

struct PickySettingsCLIEntry: Equatable {
    let key: String
    let type: PickySettingsCLIValueType
    let choices: [String]?
    let writable: Bool
    let mainAgentAllowed: Bool
    let supportsToggle: Bool
    let restartRequired: Bool
    let description: String
}

struct PickySettingsCLIExposureError: LocalizedError, Equatable {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

/// The app-owned catalog for settings that the local `picky` CLI may expose.
/// Keep this intentionally small: adding a key requires declaring its wire
/// metadata, typed validation, current-value projection, and narrow patch.
enum PickySettingsCLIExposure {
    static let entries: [PickySettingsCLIEntry] = [
        .init(key: "hud.dockVisible", type: .bool, choices: nil, writable: true, mainAgentAllowed: true, supportsToggle: true, restartRequired: false, description: "Show or hide the Pickle dock."),
        .init(key: "hud.dockSizePreset", type: .enum, choices: PickyHUDDockSizePreset.allCases.map(\.rawValue), writable: true, mainAgentAllowed: true, supportsToggle: false, restartRequired: false, description: "Pickle dock size preset."),
        .init(key: "mainAgent.model", type: .string, choices: nil, writable: true, mainAgentAllowed: true, supportsToggle: false, restartRequired: false, description: "Main agent model pattern."),
        .init(key: "mainAgent.thinkingLevel", type: .enum, choices: PickyMainAgentThinkingLevel.allCases.map(\.rawValue), writable: true, mainAgentAllowed: true, supportsToggle: false, restartRequired: false, description: "Main agent thinking level."),
        .init(key: "pickleAgent.model", type: .string, choices: nil, writable: true, mainAgentAllowed: true, supportsToggle: false, restartRequired: false, description: "Default model pattern for new Pickles."),
        .init(key: "pickleAgent.thinkingLevel", type: .enum, choices: PickyPickleAgentThinkingLevel.allCases.map(\.rawValue), writable: true, mainAgentAllowed: true, supportsToggle: false, restartRequired: false, description: "Default thinking level for new Pickles."),
        .init(key: "notifications.newPicklesNotifyMainOnCompletion", type: .bool, choices: nil, writable: false, mainAgentAllowed: false, supportsToggle: false, restartRequired: false, description: "Whether new Pickles report completion to Main Picky."),
        .init(key: "notifications.newPicklesNotifyMacOSOnCompletion", type: .bool, choices: nil, writable: false, mainAgentAllowed: false, supportsToggle: false, restartRequired: false, description: "Whether new Pickles send a macOS completion notification."),
        .init(key: "cursor.visible", type: .bool, choices: nil, writable: true, mainAgentAllowed: true, supportsToggle: true, restartRequired: false, description: "Show or hide the Picky cursor.")
    ]

    static func entry(for key: String) throws -> PickySettingsCLIEntry {
        guard let entry = entries.first(where: { $0.key == key }) else {
            throw error("SETTINGS_KEY_UNKNOWN", "Unknown Picky setting key: \(key)")
        }
        return entry
    }

    static func validateAccess(for entry: PickySettingsCLIEntry, caller: String?) throws {
        guard entry.writable else {
            throw error("SETTINGS_KEY_NOT_WRITABLE", "Picky setting is read-only: \(entry.key)")
        }
        // `caller` originates from a best-effort CLI environment marker. It is
        // policy context, not an authorization boundary.
        if caller == "mainAgent", !entry.mainAgentAllowed {
            throw error("SETTINGS_KEY_NOT_ALLOWED_FOR_MAIN_AGENT", "Picky setting is not available to the main agent: \(entry.key)")
        }
    }

    static func currentValue(for key: String, in settings: PickySettings, displayId: String? = nil) throws -> JSONValue {
        _ = try entry(for: key)
        switch key {
        case "hud.dockVisible":
            if let displayId {
                return .bool(settings.hudDockVisibilityByDisplayID[displayId] ?? settings.hudDockVisible)
            }
            return .bool(settings.hudDockVisible)
        case "hud.dockSizePreset": return .string(settings.hudDockSizePreset.rawValue)
        case "mainAgent.model": return .string(settings.mainAgentModelPattern)
        case "mainAgent.thinkingLevel": return .string(settings.mainAgentThinkingLevel.rawValue)
        case "pickleAgent.model": return .string(settings.pickleAgentModelPattern)
        case "pickleAgent.thinkingLevel": return .string(settings.pickleAgentThinkingLevel.rawValue)
        case "notifications.newPicklesNotifyMainOnCompletion": return .bool(settings.notifications.notifyMainOnCompletionForNewPickles)
        case "notifications.newPicklesNotifyMacOSOnCompletion": return .bool(settings.notifications.notifyMacOSOnCompletionForNewPickles)
        case "cursor.visible": return .bool(settings.cursor.showPiCursor)
        default:
            throw error("SETTINGS_KEY_UNKNOWN", "Unknown Picky setting key: \(key)")
        }
    }

    /// Applies one validated catalog value to an in-memory settings snapshot.
    /// The caller persists this mutation through `PickySettingsMutationCoordinator`.
    @discardableResult
    static func apply(
        key: String,
        value: JSONValue,
        toggle: Bool,
        displayId: String?,
        to settings: inout PickySettings
    ) throws -> JSONValue {
        let entry = try entry(for: key)
        guard entry.writable else {
            throw error("SETTINGS_KEY_NOT_WRITABLE", "Picky setting is read-only: \(key)")
        }
        if toggle, !entry.supportsToggle {
            throw error("SETTINGS_TOGGLE_NOT_SUPPORTED", "Picky setting does not support toggle: \(key)")
        }
        if displayId != nil, key != "hud.dockVisible" {
            throw error("SETTINGS_DISPLAY_NOT_SUPPORTED", "Display overrides are only supported for hud.dockVisible")
        }

        switch key {
        case "hud.dockVisible":
            let next = toggle
                ? !(try boolValue(for: key, in: settings, displayId: displayId))
                : try bool(value, for: key)
            if let displayId {
                if next == settings.hudDockVisible {
                    settings.hudDockVisibilityByDisplayID.removeValue(forKey: displayId)
                } else {
                    settings.hudDockVisibilityByDisplayID[displayId] = next
                }
            } else {
                settings.hudDockVisible = next
                settings.hudDockVisibilityByDisplayID = [:]
            }
            return .bool(next)
        case "hud.dockSizePreset":
            let rawValue = try string(value, for: key)
            guard let preset = PickyHUDDockSizePreset(rawValue: rawValue) else {
                throw invalidChoice(rawValue, for: entry)
            }
            settings.hudDockSizePreset = preset
            return .string(preset.rawValue)
        case "mainAgent.model":
            settings.mainAgentModelPattern = try string(value, for: key)
            return .string(settings.mainAgentModelPattern)
        case "mainAgent.thinkingLevel":
            let rawValue = try string(value, for: key)
            guard let level = PickyMainAgentThinkingLevel(rawValue: rawValue) else {
                throw invalidChoice(rawValue, for: entry)
            }
            settings.mainAgentThinkingLevel = level
            return .string(level.rawValue)
        case "pickleAgent.model":
            settings.pickleAgentModelPattern = try string(value, for: key)
            return .string(settings.pickleAgentModelPattern)
        case "pickleAgent.thinkingLevel":
            let rawValue = try string(value, for: key)
            guard let level = PickyPickleAgentThinkingLevel(rawValue: rawValue) else {
                throw invalidChoice(rawValue, for: entry)
            }
            settings.pickleAgentThinkingLevel = level
            return .string(level.rawValue)
        case "cursor.visible":
            let next = toggle ? !settings.cursor.showPiCursor : try bool(value, for: key)
            settings.cursor.showPiCursor = next
            return .bool(next)
        default:
            throw error("SETTINGS_KEY_UNKNOWN", "Unknown Picky setting key: \(key)")
        }
    }

    static func metadataPayload(for entry: PickySettingsCLIEntry, currentValue: JSONValue) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(entry.key),
            "type": .string(entry.type.rawValue),
            "writable": .bool(entry.writable),
            "mainAgentAllowed": .bool(entry.mainAgentAllowed),
            "supportsToggle": .bool(entry.supportsToggle),
            "restartRequired": .bool(entry.restartRequired),
            "currentValue": currentValue,
            "description": .string(entry.description)
        ]
        if let choices = entry.choices {
            object["choices"] = .array(choices.map(JSONValue.string))
        }
        return .object(object)
    }

    private static func boolValue(for key: String, in settings: PickySettings, displayId: String?) throws -> Bool {
        guard case .bool(let value) = try currentValue(for: key, in: settings, displayId: displayId) else {
            throw error("SETTINGS_VALUE_INVALID", "Picky setting requires a boolean: \(key)")
        }
        return value
    }

    private static func bool(_ value: JSONValue, for key: String) throws -> Bool {
        guard case .bool(let bool) = value else {
            throw error("SETTINGS_VALUE_INVALID", "Picky setting requires a boolean: \(key)")
        }
        return bool
    }

    private static func string(_ value: JSONValue, for key: String) throws -> String {
        guard case .string(let string) = value else {
            throw error("SETTINGS_VALUE_INVALID", "Picky setting requires a string: \(key)")
        }
        return string
    }

    private static func invalidChoice(_ value: String, for entry: PickySettingsCLIEntry) -> PickySettingsCLIExposureError {
        error("SETTINGS_VALUE_INVALID", "Unsupported value for \(entry.key): \(value)")
    }

    private static func error(_ code: String, _ message: String) -> PickySettingsCLIExposureError {
        PickySettingsCLIExposureError(code: code, message: message)
    }
}
