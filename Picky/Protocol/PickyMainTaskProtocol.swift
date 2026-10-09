//
//  PickyMainTaskProtocol.swift
//  Picky
//
//  Wire models for the main Picky agent's Tasks and its Pickle delegation
//  decisions, mirroring `agentd/src/features/main-tasks/schema.ts`. A Task
//  belongs to the main conversation; a delegation decision is the user's answer
//  to "hand this to a Pickle?". The daemon owns every value here — the app only
//  renders the snapshot and sends the two user controls at the bottom.
//
//  Every wire enum decodes an unrecognized value as `.unknown` instead of
//  throwing, so one new daemon status cannot drop the whole snapshot.
//

import Foundation

enum PickyMainTaskStatus: String, Codable, Equatable {
    /// Waiting for a free worker slot, not for the user.
    case queued
    case evaluating, running, waiting, stopping
    case completed, failed
    /// Needs a decision or an approval; the report carries the blockers.
    case blocked
    /// Stopped by the user.
    case cancelled
    /// Stopped because Picky quit. Resumable.
    case interrupted
    case unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

enum PickyMainTaskTier: String, Codable, Equatable {
    case fast, balanced, powerful, unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

/// The model and thinking level a Task revision runs with. Thinking stays a raw
/// string so a level a newer daemon adds cannot drop the snapshot.
struct PickyMainTaskModelSelection: Codable, Equatable {
    let provider: String
    let model: String
    let thinking: String

    var thinkingLevel: PickyMainAgentThinkingLevel? { PickyMainAgentThinkingLevel(rawValue: thinking) }
    /// `provider/model`, the same form the model menus list.
    var pattern: String { "\(provider)/\(model)" }
}

/// Set on `cancelled`. `uncertain` means Picky could not confirm the worker
/// process exited, which the UI has to say plainly rather than imply a clean stop.
enum PickyMainTaskCleanup: String, Codable, Equatable {
    case confirmed, uncertain, unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

enum PickyMainTaskReportStatus: String, Codable, Equatable {
    case success, failed, blocked, unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

enum PickyMainTaskEscalation: String, Codable, Equatable {
    case productionCode = "production_code"
    case unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

struct PickyMainTaskReport: Codable, Equatable {
    let status: PickyMainTaskReportStatus
    let summary: String
    let artifacts: [String]
    /// Checks the worker actually ran. Empty means none ran — never "passed".
    let verification: [String]
    let blockers: [String]
    let escalation: PickyMainTaskEscalation?
}

/// The Pickle that took a Task over. The Task keeps its own result as it was.
struct PickyMainTaskHandoff: Codable, Equatable {
    let decisionId: String
    let pickleSessionId: String?
}

struct PickyMainTask: Codable, Equatable, Identifiable {
    let id: String
    let revision: Int
    let title: String
    let status: PickyMainTaskStatus
    let cwd: String
    let readonly: Bool
    /// In order; a later instruction overrides an earlier one.
    let instructions: [String]
    let createdAt: Date
    let updatedAt: Date
    /// When the current revision started running. The elapsed clock counts from here.
    let revisionStartedAt: Date?
    let tier: PickyMainTaskTier?
    /// Chosen with the tier when the revision starts. Absent from older daemons.
    var selection: PickyMainTaskModelSelection? = nil
    let report: PickyMainTaskReport?
    let error: String?
    let cleanup: PickyMainTaskCleanup?
    /// The delegation decision this Task runs for, when the user chose Task over Pickle.
    let decisionId: String?
    let handoff: PickyMainTaskHandoff?
    let canStop: Bool
    let canResume: Bool
}

enum PickyMainDelegationState: String, Codable, Equatable {
    /// The user has not decided. Nothing runs, and closing the form keeps it here.
    case pending
    case pickle, task, cancelled, unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

enum PickyMainDelegationPickleState: String, Codable, Equatable {
    case creating, created, failed, unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

struct PickyMainDelegationPickle: Codable, Equatable {
    let state: PickyMainDelegationPickleState
    let sessionId: String?
    let error: String?
}

struct PickyMainDelegationDecision: Codable, Equatable, Identifiable {
    let id: String
    let state: PickyMainDelegationState
    let title: String
    let instructions: String
    let cwd: String?
    /// The question the main agent asked, in the user's language.
    let question: String?
    let createdAt: Date
    let updatedAt: Date
    /// The Task whose scope grew into production code work.
    let fromTaskId: String?
    /// The Task that runs this scope after the user chose Task.
    let taskId: String?
    let pickle: PickyMainDelegationPickle?
}

/// Payload of `mainTasksUpdated`. The daemon broadcasts the full snapshot on
/// every change and once right after a client connects.
struct PickyMainTasksSnapshot: Codable, Equatable {
    let tasks: [PickyMainTask]
    let decisions: [PickyMainDelegationDecision]

    static let empty = PickyMainTasksSnapshot(tasks: [], decisions: [])
}

// MARK: - Task models

/// A user's choice for one level in Settings. Nil fields follow the automatic
/// preset; the encoder leaves them out, which the daemon reads as automatic.
struct PickyMainTaskModelPreset: Codable, Equatable {
    struct Model: Codable, Equatable {
        let provider: String
        let id: String
    }

    var model: Model?
    var thinking: PickyMainAgentThinkingLevel?
}

/// Payload of `setMainTaskModelPresets`: every level the user customized.
struct PickyMainTaskModelPresets: Codable, Equatable {
    var fast: PickyMainTaskModelPreset?
    var balanced: PickyMainTaskModelPreset?
    var powerful: PickyMainTaskModelPreset?
}

/// What each level runs on automatic for the current main model, from
/// `mainTaskModelPresets`. The daemon sends none before the main agent starts.
struct PickyMainTaskAutomaticModels: Codable, Equatable {
    let fast: PickyMainTaskModelSelection
    let balanced: PickyMainTaskModelSelection
    let powerful: PickyMainTaskModelSelection

    subscript(tier: PickyMainTaskTier) -> PickyMainTaskModelSelection? {
        switch tier {
        case .fast: fast
        case .balanced: balanced
        case .powerful: powerful
        case .unknown: nil
        }
    }
}

/// Decoding shape of the `mainTaskModelPresets` event.
struct PickyMainTaskModelPresetsPayload: Decodable {
    let automatic: PickyMainTaskAutomaticModels?
}

// MARK: - Commands

/// User control for one Task. Raw values are the `controlMainTask` wire values.
enum PickyMainTaskControlAction: String, Codable, Equatable {
    case stop, resume

    var wire: PickyCommandAction { self == .stop ? .stop : .resume }
}

/// A user's answer to a delegation decision, usually one left `pending`.
enum PickyMainDelegationChoice: String, Codable, Equatable {
    case pickle, task, cancel
}

/// Values the shared wire key `action` carries. One `PickyCommandEnvelope`
/// property has to serve every command that uses that key, so this enum is
/// their union: `controlPushToTalkFromExternal` sends `press`/`release` and
/// `controlMainTask` sends `stop`/`resume`. The daemon rejects a value the
/// addressed command does not accept.
enum PickyCommandAction: String, Codable, Equatable {
    case press, release
    case stop, resume
    /// `picky-debug` actions. The app never sends these; they exist so a shared
    /// `debugApp` command fixture decodes on both ends. App-side handling uses
    /// `PickyDebugAppAction` from the forwarded `debugAppRequested` event.
    case snapshot, text, pttPress, pttRelease
}

extension PickyCommandEnvelope {
    static func controlMainTask(taskId: String, action: PickyMainTaskControlAction) -> PickyCommandEnvelope {
        var command = PickyCommandEnvelope(type: .controlMainTask)
        command.taskId = taskId
        command.action = action.wire
        return command
    }

    static func resolveMainDelegation(decisionId: String, choice: PickyMainDelegationChoice) -> PickyCommandEnvelope {
        var command = PickyCommandEnvelope(type: .resolveMainDelegation)
        command.decisionId = decisionId
        command.choice = choice
        return command
    }

    /// Replaces the daemon's per-level choices with the saved settings.
    static func setMainTaskModelPresets(_ presets: PickyMainTaskModelPresets) -> PickyCommandEnvelope {
        var command = PickyCommandEnvelope(type: .setMainTaskModelPresets)
        command.taskModelPresets = presets
        return command
    }
}
