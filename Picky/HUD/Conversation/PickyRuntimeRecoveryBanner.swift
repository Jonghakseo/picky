import SwiftUI

/// What the conversation card shows about an automatic runtime restart.
/// Restarting and restarted only inform; the one action is duplicating a Pickle
/// whose runtime could not be restarted.
struct PickyRuntimeRecoveryBannerPresentation: Equatable {
    enum Tone: Equatable { case progress, notice, warning }

    let titleKey: String
    let detailKey: String
    let tone: Tone
    let dismissible: Bool
    let offersDuplicate: Bool

    /// `dismissedUpdate` is the recovery timestamp the user closed, so a later restart shows again.
    init?(recovery: PickyRuntimeRecovery?, dismissedUpdate: Date?, canDuplicate: Bool) {
        guard let recovery else { return nil }
        switch recovery.phase {
        case .restarting:
            titleKey = "hud.runtimeRecovery.restarting.title"
            detailKey = "hud.runtimeRecovery.restarting.body"
            tone = .progress
            dismissible = false
            offersDuplicate = false
        case .restarted:
            guard dismissedUpdate != recovery.updatedAt else { return nil }
            titleKey = "hud.runtimeRecovery.restarted.title"
            detailKey = "hud.runtimeRecovery.restarted.body"
            tone = .notice
            dismissible = true
            offersDuplicate = false
        case .failed:
            titleKey = "hud.runtimeRecovery.failed.title"
            detailKey = canDuplicate ? "hud.runtimeRecovery.failed.body" : "hud.runtimeRecovery.failed.bodyNoDuplicate"
            tone = .warning
            dismissible = false
            offersDuplicate = canDuplicate
        }
    }
}

/// Narrow owner: reads only session metadata, so composer typing never re-renders it.
struct PickyRuntimeRecoveryBanner: View {
    let metaStore: PickySessionMetaStore
    let commands: PickySessionCommands
    @State private var dismissedUpdate: Date?
    @State private var isDuplicating = false

    var body: some View {
        if case .loaded(let metadata) = metaStore.metadataState,
           let presentation = PickyRuntimeRecoveryBannerPresentation(
               recovery: metadata.runtimeRecovery,
               dismissedUpdate: dismissedUpdate,
               canDuplicate: metadata.piSessionFilePath != nil
           ) {
            banner(presentation, sessionID: metadata.id, recovery: metadata.runtimeRecovery)
                .padding(.bottom, DS.Spacing.space2)
        }
    }

    private func banner(_ presentation: PickyRuntimeRecoveryBannerPresentation, sessionID: String, recovery: PickyRuntimeRecovery?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            icon(presentation.tone)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t(presentation.titleKey))
                        .pickyFont(size: 11.5, weight: .semibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(L10n.t(presentation.detailKey))
                        .pickyFont(size: 11)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if presentation.offersDuplicate {
                    Button(L10n.t("hud.runtimeRecovery.duplicate")) { duplicate(sessionID: sessionID) }
                        .buttonStyle(PickyQuestionPrimaryButtonStyle(isBusy: isDuplicating))
                        .disabled(isDuplicating)
                }
            }
            Spacer(minLength: 4)
            if presentation.dismissible {
                Button { dismissedUpdate = recovery?.updatedAt } label: {
                    Image(systemName: "xmark")
                        .pickyFont(size: 9, weight: .semibold)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("common.dismiss"))
                .accessibilityLabel(L10n.t("common.dismiss"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background(presentation.tone))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                .stroke(tint(presentation.tone).opacity(0.45), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func icon(_ tone: PickyRuntimeRecoveryBannerPresentation.Tone) -> some View {
        switch tone {
        case .progress:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .notice:
            Image(systemName: "info.circle")
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(tint(tone))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(tint(tone))
        }
    }

    private func tint(_ tone: PickyRuntimeRecoveryBannerPresentation.Tone) -> Color {
        tone == .warning ? DS.Colors.warningText : DS.Colors.accentText
    }

    private func background(_ tone: PickyRuntimeRecoveryBannerPresentation.Tone) -> Color {
        tone == .warning ? DS.Colors.warning.opacity(0.10) : DS.Colors.surface2.opacity(0.7)
    }

    private func duplicate(sessionID: String) {
        guard !isDuplicating else { return }
        isDuplicating = true
        Task { @MainActor in
            defer { isDuplicating = false }
            try? await commands.duplicate(sessionID: sessionID)
        }
    }
}
