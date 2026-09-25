//
//  PickyTerminalSyncBanner.swift
//  Picky
//
//  Surfaces the result of the most recent terminal-overlay-driven sync so a
//  silent skip (e.g. baseline missing because pi compacted/branched) is no
//  longer invisible to the user.
//

import SwiftUI

/// Decides whether a sync outcome is worth surfacing to the user. The
/// "baseline matched, zero new messages" case is intentionally suppressed
/// upstream in `PickySessionListViewModel`, so the banner only ever needs
/// to render the imported-N-messages and baseline-missing variants.
enum PickyTerminalSyncOutcomePolicy {
    static func shouldSurfaceBanner(for outcome: PickyTerminalSessionSyncOutcome) -> Bool {
        if !outcome.baselineFound { return true }
        return outcome.importedMessageCount > 0
    }
}

struct PickyTerminalSyncBanner: View {
    let outcome: PickyTerminalSessionSyncOutcome
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severity.iconName)
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(severity.tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(severity.title)
                    .pickyFont(size: 11.5, weight: .semibold)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(detail)
                    .pickyFont(size: 11)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .pickyFont(size: 9, weight: .semibold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("common.dismiss"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(severity.background)
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                .stroke(severity.tint.opacity(0.45), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
        .padding(.horizontal, 4)
    }

    private var severity: Severity {
        if !outcome.baselineFound { return .baselineMissing }
        return .imported(count: outcome.importedMessageCount)
    }

    private var detail: String {
        switch severity {
        case .baselineMissing:
            return L10n.t("hud.terminalSync.baselineMissing.body")
        case .imported(let count):
            return count == 1
                ? L10n.t("hud.terminalSync.imported.one")
                : L10n.t("hud.terminalSync.imported.many", count)
        }
    }

    private enum Severity: Equatable {
        case baselineMissing
        case imported(count: Int)

        var title: String {
            switch self {
            case .baselineMissing: return L10n.t("hud.terminalSync.baselineMissing.title")
            case .imported: return L10n.t("hud.terminalSync.imported.title")
            }
        }

        var iconName: String {
            switch self {
            case .baselineMissing: return "exclamationmark.triangle.fill"
            case .imported: return "arrow.triangle.2.circlepath"
            }
        }

        var tint: Color {
            switch self {
            case .baselineMissing: return DS.Colors.warningText
            case .imported: return DS.Colors.accentText
            }
        }

        var background: Color {
            switch self {
            case .baselineMissing: return DS.Colors.warning.opacity(0.10)
            case .imported: return DS.Colors.surface2.opacity(0.7)
            }
        }
    }
}
