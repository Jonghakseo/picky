//
//  PickyTaskModelPresetSettings.swift
//  Picky
//
//  The user's model choices for Picky's Tasks, one per level (Fast, Balanced,
//  Powerful). Each Task is rated into a level when it starts and runs on that
//  level's model. Automatic follows the main model's provider; the daemon owns
//  what automatic resolves to, so the app stores only the user's own choices.
//

import Foundation

/// One level's choice. An empty pattern and a nil thinking level both mean automatic.
struct PickyTaskModelPresetSetting: Codable, Equatable {
    /// `provider/model` from the model menu, or empty for automatic.
    var modelPattern: String = ""
    /// Nil follows the level's automatic thinking level, also when a model is chosen.
    var thinkingLevel: PickyMainAgentThinkingLevel?

    init(modelPattern: String = "", thinkingLevel: PickyMainAgentThinkingLevel? = nil) {
        self.modelPattern = modelPattern
        self.thinkingLevel = thinkingLevel
    }

    /// Lenient so settings written by another version still load: an unknown
    /// thinking level reads as automatic instead of resetting every setting.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelPattern = try container.decodeIfPresent(String.self, forKey: .modelPattern) ?? ""
        thinkingLevel = (try? container.decodeIfPresent(PickyMainAgentThinkingLevel.self, forKey: .thinkingLevel)) ?? nil
    }

    /// What the daemon receives; nil when the level is fully automatic.
    var wirePreset: PickyMainTaskModelPreset? {
        let model = Self.model(fromPattern: modelPattern)
        guard model != nil || thinkingLevel != nil else { return nil }
        return PickyMainTaskModelPreset(model: model, thinking: thinkingLevel)
    }

    /// Provider ids never contain a slash; model ids may (an OpenRouter id), so
    /// the pattern splits at its first one. Anything else reads as automatic.
    static func model(fromPattern pattern: String) -> PickyMainTaskModelPreset.Model? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let provider = String(trimmed[..<slash])
        let id = String(trimmed[trimmed.index(after: slash)...])
        guard !provider.isEmpty, !id.isEmpty else { return nil }
        return PickyMainTaskModelPreset.Model(provider: provider, id: id)
    }
}

/// A one-pick set of models for all three levels. Reasoning stays automatic, so each level
/// keeps its own low/medium/high default. Model ids match the daemon's `PRESET_CATALOG`
/// (`agentd/src/runtime/task/routing/config.ts`): `anthropic` is the Claude subscription
/// login and `openai-codex` the ChatGPT subscription login.
enum PickyTaskModelPresetBundle: Hashable, CaseIterable {
    case automatic
    case claudeSubscription
    case openAISubscription
    /// The choices match no bundle. Shown only as the current state, never applied.
    case custom

    static let selectable: [PickyTaskModelPresetBundle] = [.automatic, .claudeSubscription, .openAISubscription]

    var settings: PickyTaskModelPresetSettings? {
        switch self {
        case .automatic:
            return .automatic
        case .claudeSubscription:
            return Self.models("anthropic", fast: "claude-haiku-5-5", balanced: "claude-sonnet-5-5", powerful: "claude-opus-5-5")
        case .openAISubscription:
            return Self.models("openai-codex", fast: "gpt-6-luna", balanced: "gpt-6-sol", powerful: "gpt-6-astra")
        case .custom:
            return nil
        }
    }

    private static func models(_ provider: String, fast: String, balanced: String, powerful: String) -> PickyTaskModelPresetSettings {
        PickyTaskModelPresetSettings(
            fast: PickyTaskModelPresetSetting(modelPattern: "\(provider)/\(fast)"),
            balanced: PickyTaskModelPresetSetting(modelPattern: "\(provider)/\(balanced)"),
            powerful: PickyTaskModelPresetSetting(modelPattern: "\(provider)/\(powerful)")
        )
    }
}

struct PickyTaskModelPresetSettings: Codable, Equatable {
    var fast = PickyTaskModelPresetSetting()
    var balanced = PickyTaskModelPresetSetting()
    var powerful = PickyTaskModelPresetSetting()

    static let automatic = PickyTaskModelPresetSettings()

    init(
        fast: PickyTaskModelPresetSetting = PickyTaskModelPresetSetting(),
        balanced: PickyTaskModelPresetSetting = PickyTaskModelPresetSetting(),
        powerful: PickyTaskModelPresetSetting = PickyTaskModelPresetSetting()
    ) {
        self.fast = fast
        self.balanced = balanced
        self.powerful = powerful
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fast = try container.decodeIfPresent(PickyTaskModelPresetSetting.self, forKey: .fast) ?? PickyTaskModelPresetSetting()
        balanced = try container.decodeIfPresent(PickyTaskModelPresetSetting.self, forKey: .balanced) ?? PickyTaskModelPresetSetting()
        powerful = try container.decodeIfPresent(PickyTaskModelPresetSetting.self, forKey: .powerful) ?? PickyTaskModelPresetSetting()
    }

    /// The levels the settings screen lists, in order.
    static let tiers: [PickyMainTaskTier] = [.fast, .balanced, .powerful]

    subscript(tier: PickyMainTaskTier) -> PickyTaskModelPresetSetting {
        get {
            switch tier {
            case .fast: fast
            case .balanced: balanced
            case .powerful: powerful
            case .unknown: PickyTaskModelPresetSetting()
            }
        }
        set {
            switch tier {
            case .fast: fast = newValue
            case .balanced: balanced = newValue
            case .powerful: powerful = newValue
            case .unknown: break
            }
        }
    }

    var normalized: PickyTaskModelPresetSettings {
        var copy = self
        for tier in Self.tiers {
            copy[tier].modelPattern = self[tier].modelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return copy
    }

    /// Which bundle the current choices match; `.custom` once any level differs from every bundle.
    var bundle: PickyTaskModelPresetBundle {
        let current = normalized
        return PickyTaskModelPresetBundle.selectable.first { $0.settings == current } ?? .custom
    }

    /// Replaces every level with the bundle's choices. `.custom` keeps the current choices.
    mutating func apply(_ bundle: PickyTaskModelPresetBundle) {
        guard let settings = bundle.settings else { return }
        self = settings
    }

    /// The whole set replaces the daemon's, so a level set back to automatic clears its old choice.
    var wirePresets: PickyMainTaskModelPresets {
        PickyMainTaskModelPresets(fast: fast.wirePreset, balanced: balanced.wirePreset, powerful: powerful.wirePreset)
    }
}
