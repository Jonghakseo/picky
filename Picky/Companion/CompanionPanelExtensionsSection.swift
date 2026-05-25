//
//  CompanionPanelExtensionsSection.swift
//  Picky
//
//  Opt-in install/uninstall controls for bundled pi-extensions. Picky no
//  longer auto-installs anything into `~/.pi/agent/extensions` on launch;
//  this section lets the user enable each bundled extension explicitly and
//  surfaces conflicts when the target path is owned by something else.
//

import Combine
import SwiftUI

@MainActor
final class PickyExtensionsSectionViewModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        var name: String { id }
        var status: PickyExtensionInstaller.Status
        var description: String
        var isBusy: Bool
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        rows = PickyExtensionInstaller.bundledExtensions.map { name in
            Row(
                id: name,
                status: PickyExtensionInstaller.status(named: name),
                description: Self.description(for: name),
                isBusy: false
            )
        }
    }

    /// Closure the section view installs at body time so install/uninstall
    /// successes can flag a pending plugin reload on the page-level
    /// `PickyPluginReloadController`. Injected via @EnvironmentObject from the
    /// view since the view model has no access to SwiftUI environment.
    var onPluginStateChanged: (() -> Void)?

    func install(named name: String) {
        guard let index = rows.firstIndex(where: { $0.id == name }) else { return }
        rows[index].isBusy = true
        lastError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PickyExtensionInstaller.install(named: name)
            DispatchQueue.main.async { [weak self] in
                self?.applyMutationResult(name: name, result: result.mapError { $0 as Error })
            }
        }
    }

    func uninstall(named name: String) {
        guard let index = rows.firstIndex(where: { $0.id == name }) else { return }
        rows[index].isBusy = true
        lastError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PickyExtensionInstaller.uninstall(named: name)
            DispatchQueue.main.async { [weak self] in
                self?.applyMutationResult(name: name, result: result.mapError { $0 as Error })
            }
        }
    }

    private func applyMutationResult(name: String, result: Result<Void, Error>) {
        switch result {
        case .success:
            lastError = nil
            onPluginStateChanged?()
        case .failure(let error):
            lastError = error.localizedDescription
        }
        if let index = rows.firstIndex(where: { $0.id == name }) {
            rows[index].isBusy = false
            rows[index].status = PickyExtensionInstaller.status(named: name)
        }
    }

    private static func description(for name: String) -> String {
        switch name {
        case "picky-handoff":
            return L10n.t("status.extensions.pickyHandoff.description")
        default:
            return name
        }
    }
}

struct CompanionPanelExtensionsSection: View {
    @StateObject private var viewModel = PickyExtensionsSectionViewModel()
    @EnvironmentObject private var pluginReloadController: PickyPluginReloadController

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
            Image(systemName: "puzzlepiece.extension")
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14, alignment: .center)

            Text(displayName(for: row.name))
                .pickyFont(size: 11.5, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Image(systemName: "info.circle")
                .pickyFont(size: 10, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)

            statusBadge(for: row)

            Spacer(minLength: 6)

            actionButton(for: row)
        }
        .help(tooltipText(for: row))
    }

    @ViewBuilder
    private func actionButton(for row: PickyExtensionsSectionViewModel.Row) -> some View {
        switch row.status {
        case .installed:
            Button(action: { viewModel.uninstall(named: row.name) }) {
                buttonLabel(text: "status.extensions.action.remove", isBusy: row.isBusy)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(row.isBusy)
        case .notInstalled, .legacySymlink:
            Button(action: { viewModel.install(named: row.name) }) {
                buttonLabel(text: "status.extensions.action.install", isBusy: row.isBusy)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(row.isBusy)
        case .outdated:
            Button(action: { viewModel.install(named: row.name) }) {
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
                foreground: DS.Colors.success,
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
            .pickyFont(size: 9.5, weight: .medium)
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

    private func displayName(for name: String) -> String {
        switch name {
        case "picky-handoff":
            return L10n.t("status.extensions.pickyHandoff.title")
        default:
            return name
        }
    }
}
