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
                label: "생각 중",
                detail: activity.thinkingPreview.map { truncate(oneLine(PickyBubbleMarkdown.displayString(for: $0)), limit: thinkingDetailLength) },
                isRunning: true
            )
        case .tool:
            guard let toolName = activity.toolName, !toolName.isEmpty else { return nil }
            let category: PickyMainActivityChipCategory = pickleToolNames.contains(toolName) ? .pickle : .normal
            return PickyMainActivityChipModel(
                category: category,
                label: displayName(for: toolName),
                detail: detail(for: toolName, argsPreview: activity.argsPreview),
                isRunning: activity.status == "running"
            )
        }
    }

    private static let maxDetailLength = 44
    private static let thinkingDetailLength = 60
    private static let pickleToolNames: Set<String> = [
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
