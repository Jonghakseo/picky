//
//  PickyToolCallInlineRow.swift
//  Picky
//
//  Compact one-liner row representing a single tool call. Used as the
//  "what's running right now" indicator at the foot of the active turn
//  card — thinking blocks tell the user the agent is reasoning, this row
//  tells them the agent just kicked off (or finished) a concrete tool.
//
//  The completed-turn surface stays as the aggregate `PickyActivitySummaryView`
//  chip rendered on each agentActivity message; this row is intentionally
//  scoped to the current turn so it does not crowd settled history.
//

import SwiftUI

struct PickyToolCallInlineRow: View {
    let tool: PickyToolActivity
    let onTap: () -> Void

    var body: some View {
        let _ = PickyPerf.event("tool_call_inline_row_body")
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(icon)
                    .pickyFont(size: 10.5, weight: .medium, design: .monospaced)
                    .foregroundColor(categoryColor)
                    .frame(width: 12, alignment: .center)
                Text(displayedToolName)
                    .font(PickyHUDTypography.labelMonospacedMedium)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let displayedDetail, !displayedDetail.isEmpty {
                    Text(displayedDetail)
                        .font(PickyHUDTypography.metaMonospacedMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                statusIndicator
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel([displayedToolName, displayedDetail, "tool call"].compactMap { $0 }.joined(separator: " "))
        .accessibilityHint("Open tool history")
        .hoverAffordance()
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if tool.didFail {
            Circle()
                .fill(DS.Colors.destructive)
                .frame(width: 5, height: 5)
                .accessibilityLabel("Failed")
        } else if tool.isActive {
            PickyToolCallPulsingDot(color: DS.Colors.info)
                .accessibilityLabel("Running")
        } else {
            // succeeded: render a small checkmark so the user can tell the
            // call settled even while the same row keeps occupying the live
            // indicator slot during a thinking/streaming gap.
            Image(systemName: "checkmark")
                .pickyFont(size: 9, weight: .bold)
                .foregroundColor(DS.Colors.successText)
                .accessibilityLabel("Completed")
        }
    }

    private var entry: PickyToolHistoryEntry {
        PickyToolHistoryRenderer.entry(from: tool, index: 0)
    }

    private var icon: String {
        switch entry.category {
        case .read: return "📖"
        case .bash: return "⌨"
        case .edit: return "✏"
        case .write: return "▣"
        case .other: return "⋯"
        }
    }

    private var categoryColor: Color {
        switch entry.category {
        case .read: return DS.Colors.info
        case .bash: return DS.Colors.warningText
        case .edit: return DS.Colors.accentText
        case .write: return DS.Colors.floatingGradientPurple
        case .other: return DS.Colors.textSecondary
        }
    }

    var displayedToolName: String {
        PickyToolActivityPresentation.skillName(forToolNamed: tool.name, argsPreview: tool.argsPreview) == nil
            ? tool.name
            : "skill"
    }

    /// Compact second column. Pulls the most informative slice out of the
    /// parsed detail — skill name for skill invocation, file path for
    /// read/edit/write, command head for bash, truncated args preview for
    /// generic tools. Falls back to recovering the `path` field directly from
    /// the raw args preview so a truncated JSON payload still surfaces the file
    /// path the model called the tool with.
    var displayedDetail: String? {
        if let skillName = PickyToolActivityPresentation.skillName(forToolNamed: tool.name, argsPreview: tool.argsPreview) {
            return skillName
        }
        return detailText
    }

    private var detailText: String? {
        switch entry.detail {
        case let .read(file, range, _):
            let resolved = file ?? recoveredPath()
            guard let resolved else { return nil }
            let base = shortenPath(resolved)
            if let range { return "\(base) \(range)" }
            return base
        case let .bash(command, _):
            return command.map(firstLine)
        case let .edit(file, changes):
            let resolved = file ?? recoveredPath()
            guard let resolved else { return changes.isEmpty ? nil : "\(changes.count) changes" }
            let base = shortenPath(resolved)
            if changes.isEmpty { return base }
            return changes.count == 1 ? base : "\(base) (+\(changes.count))"
        case let .write(file, _):
            let resolved = file ?? recoveredPath()
            return resolved.map(shortenPath)
        case let .generic(argsJSON, _):
            return argsJSON.map(firstLine)
        }
    }

    /// Pulls a `path` value out of the raw args JSON preview when the
    /// structured detail parser missed it (e.g., the preview was truncated
    /// before the parser could decode it as JSON).
    private func recoveredPath() -> String? {
        guard let args = tool.argsPreview else { return nil }
        return PickyToolHistoryRenderer.recoverStringValue(from: args, key: "path")
    }

    private var helpText: String {
        if tool.didFail { return "Tool failed — open tool history" }
        if tool.isActive { return "Tool running — open tool history" }
        return "Open tool history"
    }

    /// Compact path display: keeps the *first* segment as a project anchor
    /// and the *last two* segments as the parent dir + filename, replacing
    /// the middle with `…`.
    ///
    /// e.g. `Picky/HUD/Conversation/Bubbles/PickyToolCallInlineRow.swift` becomes
    /// `Picky/…/Bubbles/PickyToolCallInlineRow.swift`. Paths with three or
    /// fewer segments render unchanged.
    private func shortenPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count > 3 else { return trimmed }
        let head = components[0]
        let tail = components.suffix(2).joined(separator: "/")
        return "\(head)/…/\(tail)"
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// Slowly pulsing dot used as the "running" status indicator on the active
/// tool row. Mirrors the easing of the typing-bubble dots so the two
/// in-flight signals (thinking + tool running) read as the same kind of
/// live feedback.
private struct PickyToolCallPulsingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var animating = false

    var body: some View {
        let _ = PickyPerf.event("tool_call_pulsing_dot_body")
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(accessibilityReduceMotion ? 1 : (animating ? 0.35 : 1.0))
            .animation(
                accessibilityReduceMotion ? nil : .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                value: animating
            )
            .onAppear {
                guard !accessibilityReduceMotion else { return }
                PickyPerf.event("tool_call_pulsing_dot_animation_start")
                animating = true
            }
            .onChange(of: accessibilityReduceMotion) { _, reduceMotion in
                animating = !reduceMotion
            }
    }
}
