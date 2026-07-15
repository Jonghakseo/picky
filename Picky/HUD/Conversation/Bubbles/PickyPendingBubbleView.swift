//
//  PickyPendingBubbleView.swift
//  Picky
//
//  Queued steer/follow-up bubble for conversation cards.
//

import SwiftUI

enum PickyPendingQueueKind {
    case steer
    case followUp

    var color: Color {
        switch self {
        case .steer: return DS.Colors.overlayCursorBlue
        case .followUp: return DS.Colors.success
        }
    }

    var label: String {
        switch self {
        case .steer: return "⚡ Steer · pending"
        case .followUp: return "⤵ Follow-up · pending"
        }
    }

    var batchLabel: String {
        switch self {
        case .steer: return "⚡ Steering batch · 다음 turn 에 모두 (all)"
        case .followUp: return "⤵ Follow-up batch · idle 시점에 모두 (all)"
        }
    }
}

struct PickyPendingBubbleView: View {
    let queueItem: PickyQueueItem
    let kind: PickyPendingQueueKind

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
            VStack(alignment: .leading, spacing: 5) {
                Text(PickyQueuedInputText.displayText(from: queueItem.text))
                    .font(PickyHUDTypography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                PickyConversationBubbleLayout.bubbleShape(side: .user)
                    .fill(kind.color.opacity(0.08))
            )
            .overlay(
                PickyConversationBubbleLayout.bubbleShape(side: .user)
                    .stroke(kind.color.opacity(0.48), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .frame(maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth), alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// Extracts the user-facing portion of an agentd prompt envelope so the pending
// bubble shows the original user instruction instead of the boilerplate wrapper
// that `agentd/src/prompt-builder.ts` builds (steering / follow-up envelopes).
//
// Keep the heading pairs in sync with `prompt-builder.ts`:
//   - buildSteerPrompt    : "# Picky steering message" + "## User steering instruction"
//   - buildFollowUpPrompt : "# Picky follow-up"         + "## User follow-up"
enum PickyQueuedInputText {
    /// Envelope shapes the queued item text may carry. The order does not matter;
    /// `extractUserInstruction` finds the first matching `parent` heading.
    private static let envelopes: [(parent: String, userSection: String)] = [
        ("# Picky steering message", "## User steering instruction"),
        ("# Picky follow-up", "## User follow-up"),
    ]

    static func displayText(from text: String) -> String {
        extractUserInstruction(from: text) ?? text
    }

    static func normalized(_ text: String) -> String {
        displayText(from: text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the body under the matching `## User …` section, stopping at the
    /// next `## ` heading (e.g. `## Captured context` appended by `appendContext`).
    /// Returns `nil` when the text is not an agentd envelope so callers can fall
    /// back to the raw text (legacy/plain queued items).
    private static func extractUserInstruction(from text: String) -> String? {
        guard let envelope = envelopes.first(where: { text.contains($0.parent) }),
              let headingRange = text.range(of: envelope.userSection)
        else { return nil }

        let body = text[headingRange.upperBound...]
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var extracted: [Substring] = []
        var hasStarted = false

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if !hasStarted && trimmedLine.isEmpty { continue }
            if hasStarted && trimmedLine.hasPrefix("## ") { break }
            hasStarted = true
            extracted.append(line)
        }

        let result = stripEnvelopeMetadataPrefix(from: extracted)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// `prompt-builder.ts` prefixes the user section with exactly one envelope
    /// metadata line (`- Source: …`) followed by a blank separator before the
    /// real instruction. Strip only that wrapper prefix; once user content
    /// starts, preserve it even if the user intentionally begins with
    /// `- Source: ...`.
    private static func stripEnvelopeMetadataPrefix(from lines: [Substring]) -> [Substring] {
        var result = lines
        guard let first = result.first,
              isEnvelopeMetadataLine(first.trimmingCharacters(in: .whitespaces))
        else { return result }

        result.removeFirst()
        if let separator = result.first,
           separator.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeFirst()
        }
        return result
    }

    private static func isEnvelopeMetadataLine(_ line: String) -> Bool {
        line.hasPrefix("- Source:")
    }
}
