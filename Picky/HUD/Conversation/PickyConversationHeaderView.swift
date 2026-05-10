//
//  PickyConversationHeaderView.swift
//  Picky
//
//  Header for the conversation-style Pickle card.
//

import SwiftUI

struct PickyConversationHeaderView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    let session: PickySessionListViewModel.SessionCard
    var onArchiveSession: (String) -> Void = { _ in }

    private var isVoiceFollowUpTarget: Bool {
        if let activeVoiceFollowUpSessionID = viewModel.activeVoiceFollowUpSessionID {
            return activeVoiceFollowUpSessionID == session.id
        }
        return viewModel.hoveredVoiceFollowUpSessionID == session.id
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            leadingTitle
            trailingActions
        }
        .frame(width: PickyHUDDockLayout.detailContentWidth, alignment: .trailing)
        .frame(minHeight: 26, alignment: .trailing)
    }

    private var leadingTitle: some View {
        HStack(alignment: .center, spacing: 7) {
            piBadgeSlot
            Text(session.title)
                .font(PickyHUDTypography.title)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativeTooltip(titleHelpText)
        .accessibilityHint(titleHelpText)
    }

    private var trailingActions: some View {
        HStack(alignment: .center, spacing: 8) {
            if showsHeaderSessionMeta {
                PickyHeaderSessionMetaPill(
                    assistantRun: latestAssistantRun,
                    contextUsage: session.contextUsage,
                    onCycleModel: { cycleModel() },
                    onCycleThinkingLevel: { cycleThinkingLevel() }
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            conversationMenuButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var showsHeaderSessionMeta: Bool {
        latestAssistantRun?.hasHeaderText == true || session.contextUsage != nil
    }

    private var latestAssistantRun: PickyAssistantRunMetadata? {
        session.currentAssistantRun ?? session.messages.reversed().compactMap(\.assistantRun).first
    }

    var titleHelpText: String {
        "Use /name <new title> to rename this Pickle"
    }

    private var conversationMenuButton: some View {
        Menu {
            PickyConversationMenu(session: session, viewModel: viewModel, onArchive: { onArchiveSession(session.id) })
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .frame(width: 18, height: 18)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Conversation menu")
    }

    private var piBadgeSlot: some View {
        piBadge
            .overlay(alignment: .bottomTrailing) {
                if isVoiceFollowUpTarget {
                    voiceTargetMicBadge
                }
            }
            .frame(width: 26, height: 26)
            .help(piBadgeHelpText)
            .accessibilityLabel(piBadgeAccessibilityLabel)
    }

    private var voiceTargetMicBadge: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 6.8, weight: .bold))
            .foregroundColor(DS.Colors.accentText)
            .frame(width: 11, height: 11)
            .background(Circle().fill(DS.Colors.surface1))
            .overlay(Circle().stroke(DS.Colors.accentText.opacity(0.65), lineWidth: 0.9))
            .offset(x: 3, y: 3)
    }

    private var piBadge: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(statusColor.opacity(statusFillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(statusColor.opacity(0.38), lineWidth: 0.8)
            )
            .frame(width: 22, height: 22)
            .overlay(
                PickyPiLogoGlyph()
                    .fill(statusColor, style: FillStyle(eoFill: true))
                    .frame(width: 15, height: 15)
            )
            .overlay(alignment: .topTrailing) {
                statusCornerIndicator
            }
    }

    @ViewBuilder
    private var statusCornerIndicator: some View {
        switch session.status {
        case .running:
            Circle()
                .fill(statusColor)
                .frame(width: 7.5, height: 7.5)
                .overlay(Circle().stroke(DS.Colors.surface1, lineWidth: 1.4))
                .offset(x: 2.8, y: -2.8)
        case .waiting_for_input, .blocked:
            attentionIndicator("!")
                .offset(x: 3.2, y: -3.2)
        case .failed:
            attentionIndicator("×")
                .offset(x: 3.2, y: -3.2)
        case .completed, .cancelled, .queued:
            EmptyView()
        }
    }

    private func attentionIndicator(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7.2, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .frame(width: 10, height: 10)
            .background(Circle().fill(statusColor))
            .overlay(Circle().stroke(DS.Colors.surface1, lineWidth: 1.4))
    }

    private var statusFillOpacity: Double {
        switch session.status {
        case .running: return 0.22
        case .completed, .waiting_for_input, .failed, .blocked: return 0.18
        case .queued, .cancelled: return 0.13
        }
    }

    private var piBadgeHelpText: String {
        isVoiceFollowUpTarget ? "\(statusDescription). Voice steering target" : statusDescription
    }

    private var piBadgeAccessibilityLabel: String {
        isVoiceFollowUpTarget ? "Session status: \(statusDescription), voice steering target" : "Session status: \(statusDescription)"
    }

    private var statusDescription: String {
        switch session.status {
        case .running: return "Working"
        case .completed: return "Done"
        case .waiting_for_input: return "Waiting for input"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .cancelled: return "Cancelled"
        case .queued: return "Queued"
        }
    }

    var statusColorName: String {
        switch session.status {
        case .running:
            return "blue"
        case .completed:
            return "green"
        case .waiting_for_input:
            return "amber"
        case .failed:
            return "red"
        case .blocked:
            return "warning"
        case .queued, .cancelled:
            return "tertiary"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .completed:
            return DS.Colors.success
        case .waiting_for_input:
            return DS.Colors.warning
        case .failed:
            return DS.Colors.destructiveText
        case .blocked:
            return DS.Colors.warningText
        case .queued, .cancelled:
            return DS.Colors.textTertiary
        }
    }

    private func cycleThinkingLevel() {
        Task { try? await viewModel.cycleThinkingLevel(sessionID: session.id) }
    }

    private func cycleModel() {
        Task { try? await viewModel.cycleModel(sessionID: session.id) }
    }
}

private struct PickyPiLogoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 512
        let xOffset = rect.midX - 256 * scale
        let yOffset = rect.midY - 256 * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
        }

        var path = Path()
        path.move(to: point(481, 195.71))
        path.addLines([
            point(435.32, 152.47),
            point(420.72, 91.29),
            point(359.54, 76.69),
            point(316.30, 31.01),
            point(256.01, 48.95),
            point(195.72, 31.01),
            point(152.48, 76.69),
            point(91.30, 91.29),
            point(76.70, 152.47),
            point(31.02, 195.71),
            point(48.96, 256.00),
            point(31.02, 316.29),
            point(76.70, 359.53),
            point(91.30, 420.71),
            point(152.48, 435.31),
            point(195.72, 480.99),
            point(256.01, 463.05),
            point(316.30, 480.99),
            point(359.54, 435.31),
            point(420.72, 420.71),
            point(435.32, 359.53),
            point(481.00, 316.29),
            point(463.06, 256.00),
            point(481.00, 195.71)
        ])
        path.closeSubpath()

        addEye(to: &path, centerX: 179.10, point: point)
        addEye(to: &path, centerX: 332.90, point: point)
        return path
    }

    private func addEye(
        to path: inout Path,
        centerX: CGFloat,
        point: (CGFloat, CGFloat) -> CGPoint
    ) {
        let leftX = centerX - 37.91
        let rightX = centerX + 37.91
        path.move(to: point(centerX, 291.39))
        path.addCurve(
            to: point(leftX, 244.00),
            control1: point(centerX - 20.94, 291.39),
            control2: point(leftX, 270.17)
        )
        path.addCurve(
            to: point(centerX, 196.61),
            control1: point(leftX, 217.83),
            control2: point(centerX - 20.94, 196.61)
        )
        path.addCurve(
            to: point(rightX, 244.00),
            control1: point(centerX + 20.94, 196.61),
            control2: point(rightX, 217.83)
        )
        path.addCurve(
            to: point(centerX, 291.39),
            control1: point(rightX, 270.17),
            control2: point(centerX + 20.94, 291.39)
        )
        path.closeSubpath()
    }
}

private struct PickyHeaderSessionMetaPill: View {
    let assistantRun: PickyAssistantRunMetadata?
    let contextUsage: PickyContextUsage?
    let onCycleModel: () -> Void
    let onCycleThinkingLevel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let contextDisplay {
                PickyHeaderContextUsageBar(display: contextDisplay)
                    .frame(width: 24, height: 5)
                Text(contextDisplay.label)
                    .fontWeight(.bold)
                if modelText != nil || thinkingLevelText != nil {
                    separator
                }
            }
            if let modelText {
                Button(action: onCycleModel) {
                    Text(modelText)
                        .foregroundColor(tint.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Cycle scoped model (⌃P)")
            }
            if modelText != nil, thinkingLevelText != nil {
                separator
            }
            if let thinkingLevelText {
                Button(action: onCycleThinkingLevel) {
                    Text(thinkingLevelText)
                        .foregroundColor(tint.opacity(0.92))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Cycle thinking level (⇧Tab)")
            }
        }
        .font(PickyHUDTypography.metaMonospacedMedium)
        .foregroundColor(tint.opacity(0.88))
        .lineLimit(1)
        .help(helpText)
    }

    private var separator: some View {
        Circle()
            .fill(tint.opacity(0.55))
            .frame(width: 3, height: 3)
    }

    private var contextDisplay: PickyHeaderContextUsageDisplay? {
        contextUsage.map(PickyHeaderContextUsageDisplay.init(usage:))
    }

    private var modelText: String? {
        assistantRun?.headerModelText
    }

    private var thinkingLevelText: String? {
        assistantRun?.headerThinkingLevelText
    }

    private var tint: Color {
        contextDisplay?.color ?? DS.Colors.textTertiary
    }

    private var helpText: String {
        var parts: [String] = []
        if let contextDisplay {
            parts.append(contextDisplay.tooltip)
        }
        if let modelText {
            parts.append("Model: \(modelText)")
        }
        if let thinkingLevelText {
            parts.append("Thinking: \(thinkingLevelText)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct PickyHeaderContextUsageBar: View {
    let display: PickyHeaderContextUsageDisplay

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.surface2.opacity(0.85))
                if display.isKnown {
                    Capsule()
                        .fill(display.color)
                        .frame(width: geometry.size.width * CGFloat(max(0, min(1, display.fraction))))
                }
            }
            .overlay(
                Capsule()
                    .stroke(display.color.opacity(display.isKnown ? 0.42 : 0.28), style: StrokeStyle(lineWidth: 0.6, dash: display.isKnown ? [] : [2, 2]))
            )
        }
    }
}

private struct PickyHeaderContextUsageDisplay {
    let fraction: Double
    let label: String
    let color: Color
    let tooltip: String
    let isKnown: Bool

    init(usage: PickyContextUsage) {
        guard let percent = usage.percent else {
            self.fraction = 0
            self.label = "?%"
            self.color = DS.Colors.textTertiary
            self.tooltip = "Context usage unknown after compaction until the next model response"
            self.isKnown = false
            return
        }

        let clamped = max(0, min(100, percent))
        self.fraction = clamped / 100
        self.label = "\(Int(clamped.rounded()))%"
        switch clamped {
        case 90...:
            self.color = DS.Colors.destructive
        case 70..<90:
            self.color = DS.Colors.warning
        default:
            self.color = DS.Colors.success
        }
        if let tokens = usage.tokens {
            self.tooltip = "Context usage: \(tokens.formatted())/\(usage.contextWindow.formatted()) tokens (\(Int(clamped.rounded()))%)"
        } else {
            self.tooltip = "Context usage: \(Int(clamped.rounded()))% of \(usage.contextWindow.formatted()) tokens"
        }
        self.isKnown = true
    }
}

private extension PickyAssistantRunMetadata {
    var hasHeaderText: Bool {
        headerModelText != nil || headerThinkingLevelText != nil
    }

    var headerModelText: String? {
        guard let model else { return nil }
        let leaf = model.split(separator: "/").last.map(String.init) ?? model
        let compact = ["claude-", "openai-"].reduce(leaf) { partial, prefix in
            partial.hasPrefix(prefix) ? String(partial.dropFirst(prefix.count)) : partial
        }
        let trimmed = compact.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var headerThinkingLevelText: String? {
        guard let thinkingLevel else { return nil }
        let trimmed = thinkingLevel.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
