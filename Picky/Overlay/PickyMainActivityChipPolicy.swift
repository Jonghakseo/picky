//
//  PickyMainActivityChipPolicy.swift
//  Picky
//
//  Pure display and stacking policy for main-agent cursor activity chips.
//

import Foundation

enum PickyMainActivityChipCategory: Equatable {
    case normal
    case pickle
    case thinking
}

struct PickyMainActivityChipModel: Equatable {
    let category: PickyMainActivityChipCategory
    let label: String
    let detail: String?
    let isRunning: Bool

    static func chipModel(for activity: PickyMainActivity) -> PickyMainActivityChipModel? {
        switch activity.kind {
        case .thinking:
            return PickyMainActivityChipModel(
                category: .thinking,
                label: L10n.t("overlay.activity.thinking"),
                detail: activity.thinkingPreview.map { truncate(oneLine(PickyBubbleMarkdown.displayString(for: $0)), limit: thinkingDetailLength) },
                isRunning: true
            )
        case .tool:
            guard let toolName = activity.toolName, !toolName.isEmpty else { return nil }
            let skillName = PickyToolActivityPresentation.skillName(forToolNamed: toolName, argsPreview: activity.argsPreview)
            let category: PickyMainActivityChipCategory = pickleToolNames.contains(toolName) ? .pickle : .normal
            return PickyMainActivityChipModel(
                category: category,
                label: skillName == nil ? displayName(for: toolName) : "skill",
                detail: skillName ?? detail(for: toolName, argsPreview: activity.argsPreview),
                isRunning: activity.status == "running"
            )
        }
    }

    private static let maxDetailLength = 44
    private static let thinkingDetailLength = 60
    static let pickleToolNames: Set<String> = [
        "picky_start_pickle",
        "picky_steer_pickle",
        "picky_handoff",
        "picky_side_steer",
    ]

    private static func displayName(for toolName: String) -> String {
        toolName.split(separator: "_", omittingEmptySubsequences: false).count > 1 && toolName.contains("__")
            ? toolName.components(separatedBy: "__").last ?? toolName
            : toolName
    }

    private static func detail(for toolName: String, argsPreview: String?) -> String? {
        let rawDetail: String?
        let usesFirstLineOnly: Bool
        switch toolName.lowercased() {
        case "read", "edit", "write":
            rawDetail = PickyToolHistoryRenderer.recoverStringValue(from: argsPreview, key: "path")
                .map { ($0 as NSString).lastPathComponent }
            usesFirstLineOnly = false
        case "bash":
            if let title = PickyToolHistoryRenderer.recoverStringValue(from: argsPreview, key: "title") {
                rawDetail = title
                usesFirstLineOnly = false
            } else {
                rawDetail = PickyToolHistoryRenderer.recoverStringValue(from: argsPreview, key: "command") ?? argsPreview
                usesFirstLineOnly = true
            }
        default:
            if pickleToolNames.contains(toolName) {
                rawDetail = PickyToolHistoryRenderer.recoverStringValue(from: argsPreview, key: "title")
                usesFirstLineOnly = false
            } else if let recovered = ["query", "title", "path", "url"]
                .compactMap({ PickyToolHistoryRenderer.recoverStringValue(from: argsPreview, key: $0) })
                .first {
                rawDetail = recovered
                usesFirstLineOnly = false
            } else {
                rawDetail = argsPreview
                usesFirstLineOnly = true
            }
        }

        guard let rawDetail else { return nil }
        let detail = usesFirstLineOnly
            ? rawDetail.split(whereSeparator: \.isNewline).first.map(String.init) ?? rawDetail
            : rawDetail
        let withoutUserBashPrefix = detail.hasPrefix("$ ") ? String(detail.dropFirst(2)) : detail
        let normalized = oneLine(withoutUserBashPrefix)
        guard !normalized.isEmpty, !isEmptyStructure(normalized) else { return nil }
        return truncate(normalized, limit: maxDetailLength)
    }

    /// True when the string is empty or contains only structural punctuation of
    /// an empty container (`{}`, `{ }`, `[]`, `()`), so it conveys no argument value.
    private static func isEmptyStructure(_ text: String) -> Bool {
        text.filter { !"{}[]() \t".contains($0) }.isEmpty
    }

    private static func oneLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

/// Messenger-style cursor chips for the main agent. Only activity that has a
/// human-written description or a dedicated Picky surface is shown; raw tool
/// names, paths, commands, and thinking previews stay in the tool history.
/// Design: design/proposals/messenger-ux-2026-10.md §1-1.
enum PickyMainActivityConcisePolicy {
    static let maxLabelLength = 44

    static func models(for activities: [PickyMainActivity]) -> [PickyMainActivityChipModel] {
        let visible = activities.compactMap(model(for:))
        if !visible.isEmpty { return visible }
        // The activity stack is cleared when the main turn ends, so any tool entry
        // means the turn is still working. Keeping the chip between hidden tools
        // stops it from blinking off after each call.
        guard activities.contains(where: { $0.kind == .tool }) else { return [] }
        return [PickyMainActivityChipModel(
            category: .normal,
            label: L10n.t("hud.liveStep.working"),
            detail: nil,
            isRunning: true
        )]
    }

    static func model(for activity: PickyMainActivity) -> PickyMainActivityChipModel? {
        switch activity.kind {
        case .thinking:
            // Never show the reasoning text; the label alone says Picky is thinking.
            // `.normal` keeps the pulsing dot instead of a second set of dots.
            return PickyMainActivityChipModel(
                category: .normal,
                label: L10n.t("overlay.activity.thinking"),
                detail: nil,
                isRunning: true
            )
        case .tool:
            guard let toolName = activity.toolName, !toolName.isEmpty else { return nil }
            let isRunning = activity.status == "running"
            if PickyMainActivityChipModel.pickleToolNames.contains(toolName) {
                return PickyMainActivityChipModel.chipModel(for: activity)
            }
            let value = { (key: String) in
                PickyToolHistoryRenderer.recoverStringValue(from: activity.argsPreview, key: key)
                    .map(oneLine).flatMap { $0.isEmpty ? nil : truncate($0) }
            }
            switch toolName.lowercased() {
            case "bash", "bash_async":
                guard let title = value("title") else { return nil }
                return PickyMainActivityChipModel(category: .normal, label: title, detail: nil, isRunning: isRunning)
            case "recall", "memory_recall", "vcc_recall", "session_recall":
                return memoryModel("overlay.activity.memory.recall", detail: value("query"), isRunning: isRunning)
            case "remember", "memory_remember":
                return memoryModel("overlay.activity.memory.remember", detail: value("title"), isRunning: isRunning)
            case "forget", "memory_forget":
                return memoryModel("overlay.activity.memory.forget", detail: nil, isRunning: isRunning)
            case "web_search":
                let query = value("query") ?? firstQuery(activity.argsPreview)
                return PickyMainActivityChipModel(
                    category: .normal,
                    label: L10n.t("overlay.activity.webSearch"),
                    detail: query,
                    isRunning: isRunning
                )
            default:
                guard let server = mcpServerName(toolName: toolName, argsPreview: activity.argsPreview) else { return nil }
                return PickyMainActivityChipModel(
                    category: .normal,
                    label: L10n.t("overlay.activity.mcp", server),
                    detail: nil,
                    isRunning: isRunning
                )
            }
        }
    }

    /// MCP tools arrive either directly as `mcp__<server>__<tool>` or, with Pi's
    /// default codemode exposure, inside a `codemode` script as
    /// `tools.mcp__<server>__<tool>(...)`. Both collapse to the server name.
    static func mcpServerName(toolName: String, argsPreview: String?) -> String? {
        let source: String
        if toolName.hasPrefix("mcp__") {
            source = toolName
        } else if toolName.lowercased() == "codemode", let argsPreview {
            source = argsPreview
        } else {
            return nil
        }
        guard let start = source.range(of: "mcp__") else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "__") else { return nil }
        let server = String(rest[..<end.lowerBound])
        return server.isEmpty || server.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
            ? nil : server
    }

    private static func firstQuery(_ argsPreview: String?) -> String? {
        guard let data = argsPreview?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (object["queries"] as? [String])?.first else { return nil }
        return truncate(oneLine(first))
    }

    private static func memoryModel(_ key: String, detail: String?, isRunning: Bool) -> PickyMainActivityChipModel {
        PickyMainActivityChipModel(category: .normal, label: L10n.t(key), detail: detail, isRunning: isRunning)
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String) -> String {
        text.count > maxLabelLength ? String(text.prefix(maxLabelLength)) + "…" : text
    }
}

struct PickyMainActivityStack {
    static func apply(_ new: PickyMainActivity, to current: [PickyMainActivity]) -> [PickyMainActivity] {
        guard new.kind == .tool else { return [new] }

        if let toolCallId = new.toolCallId,
           let index = current.firstIndex(where: { $0.toolCallId == toolCallId }) {
            var updated = current
            updated[index] = activity(current[index], updatingStatusTo: new.status)
            return updated
        }

        guard new.status == "running" else { return current }
        let previous = current.last.flatMap { $0.kind == .tool ? $0 : nil }
        return (previous.map { [$0] } ?? []) + [new]
    }

    private static func activity(_ existing: PickyMainActivity, updatingStatusTo status: String?) -> PickyMainActivity {
        PickyMainActivity(
            kind: existing.kind,
            toolCallId: existing.toolCallId,
            toolName: existing.toolName,
            status: status,
            argsPreview: existing.argsPreview,
            thinkingPreview: existing.thinkingPreview
        )
    }
}
