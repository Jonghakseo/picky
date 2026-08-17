//
//  PickySessionArtifactsView.swift
//  Picky
//
//  File artifacts produced by one Pickle session.
//

import AppKit
import SwiftUI

struct PickySessionArtifactRowPresentation: Equatable, Identifiable {
    enum Availability: Equatable {
        case available(URL)
        case missing
        case unavailable
    }

    let artifact: PickyArtifact
    let title: String
    let directory: String
    let availability: Availability

    var id: String { artifact.id }
    var isMissing: Bool {
        if case .missing = availability { return true }
        return false
    }

    init(
        artifact: PickyArtifact,
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.artifact = artifact
        title = PickyArtifactTrayPresentation.title(for: artifact)
        let path = artifact.path ?? ""
        directory = PickyArtifactTrayPresentation.abbreviatedPath(
            URL(fileURLWithPath: path).deletingLastPathComponent().path,
            homeURL: homeURL
        )

        switch PickyArtifactTrayPresentation.primaryAction(
            for: artifact,
            fileManager: fileManager,
            homeURL: homeURL
        ) {
        case let .revealPath(url):
            availability = .available(url)
        case .missingPath:
            availability = .missing
        case .openURL, .unavailable:
            availability = .unavailable
        }
    }
}

enum PickySessionArtifactsPresentation {
    static func fileArtifacts(from artifacts: [PickyArtifact]) -> [PickyArtifact] {
        artifacts
            .filter { $0.kind == "file" }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
    }

    static func unseenCount(artifacts: [PickyArtifact], lastSeenArtifactsAt: Date?) -> Int {
        let files = fileArtifacts(from: artifacts)
        guard let lastSeenArtifactsAt else { return files.count }
        return files.count { $0.updatedAt > lastSeenArtifactsAt }
    }
}

struct PickySessionArtifactsView: View {
    let artifacts: [PickyArtifact]

    private var rows: [PickySessionArtifactRowPresentation] {
        PickySessionArtifactsPresentation.fileArtifacts(from: artifacts)
            .map { PickySessionArtifactRowPresentation(artifact: $0) }
    }

    var body: some View {
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: DS.Spacing.xs) {
                    ForEach(rows) { row in
                        PickySessionArtifactRow(presentation: row)
                    }
                }
                .padding(DS.Spacing.sm)
            }
            .accessibilityLabel(L10n.t("hud.artifacts.accessibilityLabel"))
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "tray")
                .font(PickyHUDTypography.title)
                .foregroundStyle(DS.Colors.textTertiary)
            Text(L10n.t("hud.artifacts.empty"))
                .font(PickyHUDTypography.supporting)
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(L10n.t("hud.artifacts.empty"))
    }
}

private struct PickySessionArtifactRow: View {
    private static let relativeDateFormatter = RelativeDateTimeFormatter()

    let presentation: PickySessionArtifactRowPresentation

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: presentation.isMissing ? "doc.badge.xmark" : "doc")
                .font(PickyHUDTypography.supportingSemibold)
                .foregroundStyle(presentation.isMissing ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(PickyHUDTypography.supportingMedium)
                    .foregroundStyle(presentation.isMissing ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .strikethrough(presentation.isMissing, color: DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: DS.Spacing.xs) {
                    Text(presentation.directory)
                    Text(relativeTime)
                }
                .font(PickyHUDTypography.meta)
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rowActions
        }
        .padding(DS.Spacing.sm)
        .background(DS.Colors.surface2.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        .opacity(presentation.isMissing ? 0.62 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var rowActions: some View {
        switch presentation.availability {
        case let .available(url):
            Button { NSWorkspace.shared.open(url) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help(L10n.t("hud.artifacts.action.open"))
            .accessibilityLabel(L10n.t("hud.artifacts.action.open"))
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Image(systemName: "folder")
            }
            .help(L10n.t("hud.artifacts.action.reveal"))
            .accessibilityLabel(L10n.t("hud.artifacts.action.reveal"))
        case .missing, .unavailable:
            EmptyView()
        }

        if let path = presentation.artifact.path {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help(L10n.t("hud.artifacts.action.copyPath"))
            .accessibilityLabel(L10n.t("hud.artifacts.action.copyPath"))
        }
    }

    private var relativeTime: String {
        Self.relativeDateFormatter.localizedString(for: presentation.artifact.updatedAt, relativeTo: Date())
    }
}
