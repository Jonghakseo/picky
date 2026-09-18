//
//  CompanionPanelExtensionsSection.swift
//  Picky
//
//  Opt-in install/uninstall controls for bundled Pi resources. Picky no
//  longer auto-installs anything into `~/.pi/agent` on launch; this section
//  lets the user enable each bundled extension/skill explicitly and surfaces
//  conflicts when the target path is owned by something else.
//

import Combine
import SwiftUI

enum PickyBundledPluginKind: String, Equatable {
    case `extension`
    case skill
}

enum PickyBundledPluginStatus: Equatable {
    case bundleMissing
    case notInstalled
    case installed
    case outdated
    case legacySymlink
    case developerOverride(target: String)
    case conflict(reason: String)

    init(_ status: PickyExtensionInstaller.Status) {
        switch status {
        case .bundleMissing: self = .bundleMissing
        case .notInstalled: self = .notInstalled
        case .installed: self = .installed
        case .outdated: self = .outdated
        case .legacySymlink: self = .legacySymlink
        case .developerOverride(let target): self = .developerOverride(target: target)
        case .conflict(let reason): self = .conflict(reason: reason)
        }
    }

    init(_ status: PickySkillInstaller.Status) {
        switch status {
        case .bundleMissing: self = .bundleMissing
        case .notInstalled: self = .notInstalled
        case .installed: self = .installed
        case .outdated: self = .outdated
        case .legacySymlink: self = .legacySymlink
        case .developerOverride(let target): self = .developerOverride(target: target)
        case .conflict(let reason): self = .conflict(reason: reason)
        }
    }
}

@MainActor
final class PickyExtensionsSectionViewModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: PickyBundledPluginKind
        var status: PickyBundledPluginStatus
        var description: String
        var isBusy: Bool
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var lastError: String?

    @Published private(set) var mutationOutcome: PickyCuratedPluginsViewModel.MutationOutcome?
    private let bundleResourceURL: URL?
    private let homeURL: URL

    init(bundleResourceURL: URL? = Bundle.main.resourceURL,
         homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.bundleResourceURL = bundleResourceURL
        self.homeURL = homeURL
        refresh()
    }

    func refresh() {
        let busyIDs = Set(rows.filter(\.isBusy).map(\.id))
        let extensionRows = PickyExtensionInstaller.bundledExtensions.map { name in
            Row(
                id: Self.rowID(kind: .extension, name: name),
                name: name,
                kind: .extension,
                status: PickyBundledPluginStatus(
                    PickyExtensionInstaller.status(named: name, bundleResourceURL: bundleResourceURL, homeURL: homeURL)
                ),
                description: Self.description(for: name, kind: .extension),
                isBusy: false
            )
        }
        let skillRows = PickySkillInstaller.bundledSkills.map { name in
            Row(
                id: Self.rowID(kind: .skill, name: name),
                name: name,
                kind: .skill,
                status: PickyBundledPluginStatus(
                    PickySkillInstaller.status(named: name, bundleResourceURL: bundleResourceURL, homeURL: homeURL)
                ),
                description: Self.description(for: name, kind: .skill),
                isBusy: false
            )
        }
        rows = (extensionRows + skillRows).map { row in
            var row = row
            row.isBusy = busyIDs.contains(row.id)
            return row
        }
    }

    /// The owning surface flags its reload controller after a successful mutation.
    var onPluginStateChanged: (() -> Void)?

    @discardableResult
    func install(_ row: Row) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == row.id }), !rows[index].isBusy else { return false }
        rows[index].isBusy = true
        lastError = nil
        let bundleResourceURL = self.bundleResourceURL
        let homeURL = self.homeURL
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            switch row.kind {
            case .extension:
                result = PickyExtensionInstaller.install(
                    named: row.name, bundleResourceURL: bundleResourceURL, homeURL: homeURL
                ).mapError { $0 as Error }
            case .skill:
                result = PickySkillInstaller.install(
                    named: row.name, bundleResourceURL: bundleResourceURL, homeURL: homeURL
                ).mapError { $0 as Error }
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyMutationResult(rowID: row.id, result: result)
            }
        }
        return true
    }

    @discardableResult
    func uninstall(_ row: Row) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == row.id }), !rows[index].isBusy else { return false }
        rows[index].isBusy = true
        lastError = nil
        let bundleResourceURL = self.bundleResourceURL
        let homeURL = self.homeURL
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            switch row.kind {
            case .extension:
                result = PickyExtensionInstaller.uninstall(
                    named: row.name, bundleResourceURL: bundleResourceURL, homeURL: homeURL
                ).mapError { $0 as Error }
            case .skill:
                result = PickySkillInstaller.uninstall(
                    named: row.name, bundleResourceURL: bundleResourceURL, homeURL: homeURL
                ).mapError { $0 as Error }
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyMutationResult(rowID: row.id, result: result)
            }
        }
        return true
    }

    private func applyMutationResult(rowID: String, result: Result<Void, Error>) {
        switch result {
        case .success:
            lastError = nil
            onPluginStateChanged?()
        case .failure(let error):
            lastError = error.localizedDescription
        }
        if let index = rows.firstIndex(where: { $0.id == rowID }) {
            rows[index].isBusy = false
            rows[index].status = status(for: rows[index])
        }
        mutationOutcome = .init(
            pluginID: rows.first(where: { $0.id == rowID })?.name ?? rowID,
            result: result.mapError { .failed($0.localizedDescription) }
        )
    }

    private func status(for row: Row) -> PickyBundledPluginStatus {
        switch row.kind {
        case .extension:
            return PickyBundledPluginStatus(
                PickyExtensionInstaller.status(named: row.name, bundleResourceURL: bundleResourceURL, homeURL: homeURL)
            )
        case .skill:
            return PickyBundledPluginStatus(
                PickySkillInstaller.status(named: row.name, bundleResourceURL: bundleResourceURL, homeURL: homeURL)
            )
        }
    }

    private static func description(for name: String, kind: PickyBundledPluginKind) -> String {
        switch (kind, name) {
        case (.extension, "picky-handoff"):
            return L10n.t("status.extensions.pickyHandoff.description")
        case (.skill, "picky-cli"):
            return L10n.t("status.extensions.pickyCLI.description")
        default:
            return name
        }
    }

    private static func rowID(kind: PickyBundledPluginKind, name: String) -> String {
        "\(kind.rawValue):\(name)"
    }
}

struct CompanionPanelExtensionsSection: View {
    @StateObject private var viewModel = PickyExtensionsSectionViewModel()
    @EnvironmentObject private var pluginReloadController: PickyPluginReloadController
    /// Name of the row whose info popover is currently open. macOS hover
    /// tooltips are unreliable on translucent panels, so the info icon doubles
    /// as a click-to-toggle popover; only one popover at a time so a single
    /// optional name is enough.
    @State private var infoPopoverRowName: String?

    var body: some View {
        let visibleRows = viewModel.rows.filter { $0.status != .bundleMissing }
        if !visibleRows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("status.extensions.heading")
                    .pickyFont(size: 11, weight: .semibold)
                    .foregroundColor(DS.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleRows) { row in
                        rowView(row)
                    }
                }

                if let lastError = viewModel.lastError {
                    Text(lastError)
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear {
                viewModel.refresh()
                // Forward install/uninstall completions to the page-level
                // reload controller so the banner shows up immediately.
                viewModel.onPluginStateChanged = { [weak controller = pluginReloadController] in
                    controller?.notePluginsChanged()
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: PickyExtensionsSectionViewModel.Row) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: iconName(for: row.kind))
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14, alignment: .center)

            Text(displayName(for: row))
                .pickyFont(size: 11.5, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            infoButton(for: row)

            statusBadge(for: row)

            Spacer(minLength: 6)

            actionButton(for: row)
        }
    }

    @ViewBuilder
    private func infoButton(for row: PickyExtensionsSectionViewModel.Row) -> some View {
        let isOpen = infoPopoverRowName == row.name
        Button(action: {
            infoPopoverRowName = isOpen ? nil : row.name
        }) {
            Image(systemName: "info.circle")
                .pickyFont(size: 10, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .buttonStyle(CompanionPanelIconActionStyle())
        .help(tooltipText(for: row))
        .accessibilityLabel(Text(tooltipText(for: row)))
        .popover(
            isPresented: Binding(
                get: { infoPopoverRowName == row.name },
                set: { presented in
                    if !presented, infoPopoverRowName == row.name { infoPopoverRowName = nil }
                }
            ),
            arrowEdge: .bottom
        ) {
            Text(tooltipText(for: row))
                .pickyFont(size: 11.5, weight: .medium)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func actionButton(for row: PickyExtensionsSectionViewModel.Row) -> some View {
        switch row.status {
        case .installed:
            Button(action: { viewModel.uninstall(row) }) {
                buttonLabel(text: "status.extensions.action.remove", isBusy: row.isBusy)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(row.isBusy)
        case .notInstalled, .legacySymlink:
            Button(action: { viewModel.install(row) }) {
                buttonLabel(text: "status.extensions.action.install", isBusy: row.isBusy)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(row.isBusy)
        case .outdated:
            Button(action: { viewModel.install(row) }) {
                buttonLabel(text: "status.extensions.action.update", isBusy: row.isBusy)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(row.isBusy)
        case .developerOverride, .conflict, .bundleMissing:
            EmptyView()
        }
    }

    private func buttonLabel(text: LocalizedStringKey, isBusy: Bool) -> some View {
        HStack(spacing: 5) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 10, height: 10)
            }
            Text(text)
        }
    }

    @ViewBuilder
    private func statusBadge(for row: PickyExtensionsSectionViewModel.Row) -> some View {
        switch row.status {
        case .installed:
            badgePill(
                text: L10n.t("status.extensions.state.installed"),
                foreground: DS.Colors.successText,
                background: DS.Colors.success.opacity(0.18)
            )
        case .outdated:
            badgePill(
                text: L10n.t("status.extensions.state.outdated"),
                foreground: DS.Colors.warningText,
                background: DS.Colors.warning.opacity(0.18)
            )
        case .legacySymlink:
            badgePill(
                text: L10n.t("status.extensions.badge.legacySymlink"),
                foreground: DS.Colors.warningText,
                background: DS.Colors.warning.opacity(0.18)
            )
        case .developerOverride:
            badgePill(
                text: L10n.t("status.extensions.badge.developerOverride"),
                foreground: DS.Colors.textSecondary,
                background: DS.Colors.textTertiary.opacity(0.16)
            )
        case .conflict:
            badgePill(
                text: L10n.t("status.extensions.badge.conflict"),
                foreground: DS.Colors.destructiveText,
                background: DS.Colors.destructive.opacity(0.15)
            )
        case .notInstalled, .bundleMissing:
            EmptyView()
        }
    }

    private func badgePill(text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(PickyHUDTypography.badgeSemibold)
            .foregroundColor(foreground)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule(style: .continuous).fill(background)
            )
            .fixedSize()
    }

    private func tooltipText(for row: PickyExtensionsSectionViewModel.Row) -> String {
        switch row.status {
        case .developerOverride(let target):
            return row.description + "\n\n" + L10n.t("status.extensions.state.developerOverride", target)
        case .conflict(let reason):
            return row.description + "\n\n" + L10n.t("status.extensions.state.conflict", reason)
        case .legacySymlink:
            return row.description + "\n\n" + L10n.t("status.extensions.state.legacySymlink")
        case .installed, .outdated, .notInstalled, .bundleMissing:
            return row.description
        }
    }

    private func displayName(for row: PickyExtensionsSectionViewModel.Row) -> String {
        switch (row.kind, row.name) {
        case (.extension, "picky-handoff"):
            return L10n.t("status.extensions.pickyHandoff.title")
        case (.skill, "picky-cli"):
            return L10n.t("status.extensions.pickyCLI.title")
        default:
            return row.name
        }
    }

    private func iconName(for kind: PickyBundledPluginKind) -> String {
        switch kind {
        case .extension:
            return "puzzlepiece.extension"
        case .skill:
            return "text.book.closed"
        }
    }
}
