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

    @State private var isExpanded = false
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        let _ = PickyPerf.event("user_bubble_body")
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
            PickyUserBubbleSurfaceView(
                markdown: displayedMarkdown,
                skillName: displayedSkillName,
                attachedImagesLabel: displayedAttachedImagesLabel,
                originLabel: originLabel,
                isPiExtensionMessage: isPiExtensionMessage,
                maxBubbleWidth: bubbleMaxWidth,
                expansionTitle: expansionTitle,
                expansionSystemImageName: expansionSystemImageName,
                onToggleExpansion: expansionAction,
                onOpenAsReport: textViewOpenAsReportAction,
                onCopyText: copyTextAction,
                onEditText: editTextAction
            )
            .frame(width: bubbleMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onChange(of: message.id) { _, _ in isExpanded = false }
    }

    var displayedSkillName: String? {
        PickySkillInvocationPresentation.invocation(for: message)?.name
    }
    var displayedMarkdownPreview: String {
        if let invocation = PickySkillInvocationPresentation.invocation(for: message) {
            return PickyAgentResponsePreview.truncatedMarkdown(invocation.instruction)
        }
        return PickyAgentResponsePreview.truncatedMarkdown(message.text ?? "")
    }
    var displayedMarkdown: String {
        isExpanded ? message.text ?? "" : displayedMarkdownPreview
    }
    var shouldOfferExpansion: Bool {
        PickySkillInvocationPresentation.invocation(for: message) != nil
            || PickyAgentResponsePreview.isTruncated(message.text ?? "")
    }

    private var expansionTitle: String? {
        guard shouldOfferExpansion else { return nil }
        return isExpanded ? "접기" : "더 보기"
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
