//
//  PickyUserBubbleView.swift
//  Picky
//
//  User-authored message bubble for conversation cards.
//

import Foundation
import SwiftUI

struct PickyUserBubbleView: View {
    let message: PickySessionMessage
    var onOpenAsReport: (() -> Void)? = nil
    var onCopyText: ((String) -> Void)? = nil
    var onEditText: ((String) -> Void)? = nil
    /// Send time shown beside the bubble end on hover. `nil` hides it.
    var timestamp: PickyBubbleTimestamp? = nil

    @State private var isExpanded = false
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        let _ = PickyPerf.event("user_bubble_body")
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
            PickyUserBubbleSurfaceView(
                markdown: displayedMarkdown,
                header: displayedHeader,
                attachedImagesLabel: displayedAttachedImagesLabel,
                originLabel: originLabel,
                isPiExtensionMessage: isPiExtensionMessage,
                maxBubbleWidth: bubbleMaxWidth,
                expansionTitle: expansionTitle,
                expansionSystemImageName: expansionSystemImageName,
                onToggleExpansion: expansionAction,
                onOpenAsReport: textViewOpenAsReportAction,
                onCopyText: copyTextAction,
                onEditText: editTextAction,
                timestamp: timestamp
            )
            .pickyBubbleTimestampAccessibility(timestamp)
            .frame(width: bubbleMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onChange(of: message.id) { _, _ in isExpanded = false }
    }

    var displayedSkillName: String? {
        PickySkillInvocationPresentation.invocation(for: message)?.name
    }
    var displayedCommandInvocation: PickyCommandInvocation? {
        PickyCommandInvocationPresentation.invocation(for: message)
    }
    var displayedHeader: PickyUserBubbleHeader? {
        if let command = displayedCommandInvocation {
            return PickyUserBubbleHeader(kind: command.failed ? .failedCommand : .command, title: command.name)
        }
        return displayedSkillName.map { PickyUserBubbleHeader(kind: .skill, title: $0) }
    }
    var displayedMarkdownPreview: String {
        if let command = displayedCommandInvocation {
            return PickyAgentResponsePreview.truncatedMarkdown(command.arguments)
        }
        if let invocation = PickySkillInvocationPresentation.invocation(for: message) {
            return PickyAgentResponsePreview.truncatedMarkdown(invocation.instruction)
        }
        return PickyAgentResponsePreview.truncatedMarkdown(message.text ?? "")
    }
    var displayedMarkdown: String {
        guard isExpanded else { return displayedMarkdownPreview }
        // A command's raw text only repeats the header, so expansion reveals the full arguments.
        if let command = displayedCommandInvocation { return command.arguments }
        return message.text ?? ""
    }
    var shouldOfferExpansion: Bool {
        if let command = displayedCommandInvocation {
            return PickyAgentResponsePreview.isTruncated(command.arguments)
        }
        return PickySkillInvocationPresentation.invocation(for: message) != nil
            || PickyAgentResponsePreview.isTruncated(message.text ?? "")
    }

    private var expansionTitle: String? {
        guard shouldOfferExpansion else { return nil }
        return isExpanded ? L10n.t("common.collapse") : L10n.t("common.showMore")
    }

    private var expansionSystemImageName: String? {
        guard shouldOfferExpansion else { return nil }
        return isExpanded ? "chevron.up" : "chevron.down"
    }

    private var expansionAction: (() -> Void)? {
        guard shouldOfferExpansion else { return nil }
        return {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        }
    }

    private var actionText: String? {
        let text = message.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private var copyTextAction: (() -> Void)? {
        guard let actionText, let onCopyText else { return nil }
        return { onCopyText(actionText) }
    }

    private var editTextAction: (() -> Void)? {
        guard let actionText, let onEditText else { return nil }
        return { onEditText(actionText) }
    }

    private var bubbleMaxWidth: CGFloat {
        PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth)
    }

    /// Mirrors the SwiftUI `.contextMenu` "Open as Report" gate so the
    /// in-text right-click menu only offers the action when the bubble's
    /// content is actually truncated in the preview.
    private var textViewOpenAsReportAction: (() -> Void)? {
        guard let onOpenAsReport, shouldOfferExpansion else { return nil }
        return onOpenAsReport
    }

    private var isPiExtensionMessage: Bool {
        message.originatedBy == .piExtension
    }

    /// Pi-extension origin is conveyed by the bubble tint (and the skill chip when
    /// present) — the "from Pi terminal" caption was pure chrome and is gone.
    private var originLabel: String? {
        message.originatedBy == .mainAgent ? "by Picky" : nil
    }

    var displayedOriginLabel: String? { originLabel }

    var displayedAttachedImagesLabel: String? {
        guard let count = message.attachedImagesCount, count > 0 else { return nil }
        return "🖥️ \(count) attached"
    }
}

/// Header row drawn above a user bubble body: the invoked skill or slash command.
struct PickyUserBubbleHeader: Equatable {
    enum Kind: Equatable {
        case skill
        case command
        case failedCommand

        var symbolName: String {
            switch self {
            case .skill: "bolt.fill"
            case .command: "slash.circle"
            case .failedCommand: "exclamationmark.circle"
            }
        }

        var iconColor: Color {
            switch self {
            case .skill: DS.Colors.info
            case .command: DS.Colors.textSecondary
            case .failedCommand: DS.Colors.destructiveText
            }
        }

        var metaText: String {
            switch self {
            case .skill: "Skill"
            case .command: "Command"
            case .failedCommand: L10n.t("hud.command.failed")
            }
        }
    }

    let kind: Kind
    let title: String
}

struct PickyCommandInvocation: Equatable {
    let name: String
    let arguments: String
    let failed: Bool
}

/// Splits a recorded slash-command receipt (`/name OAuth bug`) into the command
/// name shown in the header and the arguments shown as the bubble body.
enum PickyCommandInvocationPresentation {
    private static let pattern = try? NSRegularExpression(pattern: #"\A/(\S+)(?:\s+([\s\S]*))?\z"#)

    static func invocation(for message: PickySessionMessage) -> PickyCommandInvocation? {
        guard message.kind == .commandReceipt, let pattern else { return nil }
        let raw = (message.commandReceipt?.command ?? message.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = pattern.firstMatch(in: raw, range: range),
              let nameRange = Range(match.range(at: 1), in: raw)
        else { return nil }
        let arguments = Range(match.range(at: 2), in: raw).map { String(raw[$0]) } ?? ""
        return PickyCommandInvocation(
            name: String(raw[nameRange]),
            arguments: arguments.trimmingCharacters(in: .whitespacesAndNewlines),
            failed: message.commandReceipt?.status == .failed
        )
    }
}

struct PickySkillInvocation: Equatable {
    let name: String
    let instruction: String
}

enum PickySkillInvocationPresentation {
    private static let openingTagPattern = try? NSRegularExpression(
        pattern: #"\A\s*<skill\b[^>]*\bname\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let closingTagPattern = try? NSRegularExpression(
        pattern: #"</skill\s*>"#,
        options: [.caseInsensitive]
    )

    private static let slashCommandPattern = try? NSRegularExpression(
        pattern: #"\A/skill:([\w.-]+)(?:\s+([\s\S]*))?\z"#
    )

    /// Both invocation shapes render the chip: the raw `/skill:name instruction` the user
    /// typed (the only bubble left now that expansion echoes are suppressed) and the
    /// expanded `<skill>` XML echo for sessions where the echo still surfaces.
    static func invocation(for message: PickySessionMessage) -> PickySkillInvocation? {
        guard message.kind == .userText, let text = message.text else { return nil }
        if message.originatedBy == .piExtension {
            return invocation(in: text)
        }
        return slashInvocation(in: text)
    }

    private static func slashInvocation(in text: String) -> PickySkillInvocation? {
        guard let slashCommandPattern else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = slashCommandPattern.firstMatch(in: trimmed, range: fullRange),
              let nameRange = Range(match.range(at: 1), in: trimmed)
        else { return nil }
        let instruction = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
        return PickySkillInvocation(
            name: String(trimmed[nameRange]),
            instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func invocation(in text: String) -> PickySkillInvocation? {
        guard let openingTagPattern, let closingTagPattern else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let openingMatch = openingTagPattern.firstMatch(in: text, range: fullRange),
              let nameRange = Range(openingMatch.range(at: 1), in: text),
              let openingEnd = Range(openingMatch.range, in: text)?.upperBound
        else { return nil }

        let name = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let suffixRange = NSRange(openingEnd..<text.endIndex, in: text)
        guard let closingMatch = closingTagPattern.firstMatch(in: text, range: suffixRange),
              let closingEnd = Range(closingMatch.range, in: text)?.upperBound
        else { return nil }

        return PickySkillInvocation(
            name: name,
            instruction: String(text[closingEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
