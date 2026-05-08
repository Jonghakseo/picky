//
//  PickyTerminalSyncBanner.swift
//  Picky
//
//  Surfaces the result of the most recent terminal-overlay-driven sync so a
//  silent skip (e.g. baseline missing because pi compacted/branched) is no
//  longer invisible to the user.
//

import SwiftUI

struct PickyTerminalSyncBanner: View {
    let outcome: PickyTerminalSessionSyncOutcome
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severity.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(severity.tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(severity.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(severity.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(severity.tint.opacity(0.45), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 4)
    }

    private var severity: Severity {
        if !outcome.baselineFound { return .baselineMissing }
        if outcome.importedMessageCount == 0 { return .noChanges }
        return .imported(count: outcome.importedMessageCount)
    }

    private var detail: String {
        switch severity {
        case .baselineMissing:
            return "Pi may have compacted or branched the transcript while the terminal was open. The card was not updated. Open the terminal again or copy the resume command if you need the latest answer."
        case .noChanges:
            return "Nothing new to import."
        case .imported(let count):
            return count == 1
                ? "1 new message was imported from the terminal session."
                : "\(count) new messages were imported from the terminal session."
        }
    }

    private enum Severity: Equatable {
        case baselineMissing
        case noChanges
        case imported(count: Int)

        var title: String {
            switch self {
            case .baselineMissing: return "Terminal sync skipped"
            case .noChanges: return "Terminal sync"
            case .imported: return "Terminal sync"
            }
        }

        var iconName: String {
            switch self {
            case .baselineMissing: return "exclamationmark.triangle.fill"
            case .noChanges, .imported: return "arrow.triangle.2.circlepath"
            }
        }

        var tint: Color {
            switch self {
            case .baselineMissing: return DS.Colors.warningText
            case .noChanges: return DS.Colors.textSecondary
            case .imported: return DS.Colors.accentText
            }
        }

        var background: Color {
            switch self {
            case .baselineMissing: return DS.Colors.warning.opacity(0.10)
            case .noChanges: return DS.Colors.surface2.opacity(0.5)
            case .imported: return DS.Colors.surface2.opacity(0.7)
            }
        }
    }
}
