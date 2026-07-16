//
//  PickyArtifactTrayView.swift
//  Picky
//
//  Transient HUD surface for every artifact attached to a Pickle session.
//

import AppKit
import SwiftUI

struct PickyArtifactTrayButton: View {
    let artifacts: [PickyArtifact]
    @State private var isPresented = false

    var body: some View {
        let count = PickyArtifactTrayPresentation.trayCount(for: artifacts)
        Button { isPresented = true } label: {
            Label("\(count)", systemImage: "tray.full")
                .font(PickyHUDTypography.badgeSemibold)
                .foregroundColor(DS.Colors.accentText)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(DS.Colors.accentSubtle.opacity(0.75)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.t("hud.artifactTray.help", Int64(count)))
        .accessibilityLabel(L10n.t("hud.artifactTray.accessibilityLabel", Int64(count)))
        .pointerCursor()
        // PickyHUDPanel is key-capable despite its nonactivating style, so a native
        // popover preserves macOS focus and Escape dismissal without a custom panel.
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PickyArtifactTrayPopover(artifacts: artifacts, isPresented: $isPresented)
        }
    }
}

private struct PickyArtifactTrayPopover: View {
    let artifacts: [PickyArtifact]
    @Binding var isPresented: Bool
    @State private var copiedArtifactID: String?
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("hud.artifactTray.title"))
                .font(PickyHUDTypography.supportingSemibold)
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(artifacts) { artifact in
                        PickyArtifactTrayRow(
                            artifact: artifact,
                            copied: copiedArtifactID == artifact.id,
                            onCopy: { copy(artifact) }
                        )
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 320, alignment: .leading)
        .padding(.bottom, 6)
        .background(PickyHUDMaterialFill(shape: shape, fallback: DS.Colors.surface1))
        .overlay(shape.stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 0.8))
        .clipShape(shape)
        .onExitCommand { isPresented = false }
        .onDisappear { copyFeedbackTask?.cancel() }
    }

    private func copy(_ artifact: PickyArtifact) {
        guard let value = PickyArtifactTrayPresentation(artifact: artifact).copyValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copyFeedbackTask?.cancel()
        copiedArtifactID = artifact.id
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copiedArtifactID = nil
        }
    }
}

private struct PickyArtifactTrayRow: View {
    let artifact: PickyArtifact
    let copied: Bool
    let onCopy: () -> Void

    private var presentation: PickyArtifactTrayPresentation {
        PickyArtifactTrayPresentation(artifact: artifact)
    }

    private var isPrimaryActionAvailable: Bool {
        switch presentation.action {
        case .openURL, .revealPath:
            true
        case .missingPath, .unavailable:
            false
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: performPrimaryAction) {
                HStack(spacing: 8) {
                    PickyArtifactTrayIcon(artifact: artifact)
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.title)
                            .font(PickyHUDTypography.supportingMedium)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(PickyHUDTypography.status)
                            .foregroundStyle(subtitleColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isPrimaryActionAvailable)
            .accessibilityLabel("\(presentation.title), \(subtitle)")
            .accessibilityHint(primaryActionHint)

            if presentation.copyValue != nil {
                Button(action: onCopy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(PickyHUDTypography.statusSemibold)
                        .foregroundStyle(copied ? DS.Colors.successText : DS.Colors.accentText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t(copied ? "hud.artifactTray.copied" : "hud.artifactTray.copy"))
                .accessibilityLabel(L10n.t(copied ? "hud.artifactTray.copied" : "hud.artifactTray.copy"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .opacity(isPrimaryActionAvailable ? 1 : 0.58)
        .background(rowBackground)
    }

    private var subtitle: String {
        if case .missingPath = presentation.action {
            return L10n.t("hud.artifactTray.missingSubtitle", presentation.subtitle)
        }
        return presentation.subtitle
    }

    private var subtitleColor: Color {
        if case .missingPath = presentation.action {
            return DS.Colors.destructiveText
        }
        return DS.Colors.textTertiary
    }

    private var primaryActionHint: String {
        switch presentation.action {
        case .openURL:
            L10n.t("hud.artifactTray.openURL")
        case .revealPath:
            L10n.t("hud.artifactTray.revealPath")
        case .missingPath:
            L10n.t("hud.artifactTray.missing")
        case .unavailable:
            ""
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
            .fill(DS.Colors.surface2.opacity(0.5))
    }

    private func performPrimaryAction() {
        switch presentation.action {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .revealPath(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .missingPath, .unavailable:
            break
        }
    }
}

private struct PickyArtifactTrayIcon: View {
    let artifact: PickyArtifact

    var body: some View {
        switch artifact.linkBadgeKind {
        case .github:
            brandAsset("github-logo", template: true)
        case .slack:
            brandAsset("slack-logo")
        case .notion:
            brandAsset("notion-logo")
        case .jira:
            brandAsset("jira-logo")
        case .sentry:
            brandAsset("sentry-logo", template: true)
                .foregroundStyle(DS.Integration.Sentry.logo)
        case .linear:
            brandAsset("linear-logo")
        case .figma:
            brandAsset("figma-logo")
        case .googleDocs:
            brandAsset("google-docs-logo")
        case .googleSheets:
            brandAsset("google-sheets-logo")
        case .googleSlides:
            brandAsset("google-slides-logo")
        case .googleDrive:
            brandAsset("google-drive-logo")
        case nil:
            Image(systemName: artifact.path == nil ? "doc.text" : "doc")
                .font(PickyHUDTypography.supportingSemibold)
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private func brandAsset(_ name: String, template: Bool = false) -> some View {
        Image(name)
            .renderingMode(template ? .template : .original)
            .resizable()
            .scaledToFit()
    }
}
