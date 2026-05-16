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

    var body: some View {
        let visibleRows = viewModel.rows.filter { $0.status != .bundleMissing }
        if !visibleRows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("status.extensions.heading")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleRows) { row in
                        rowView(row)
                    }
                }

                if let lastError = viewModel.lastError {
                    Text(lastError)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { viewModel.refresh() }
        }
    }

    @ViewBuilder
    private func rowView(_ row: PickyExtensionsSectionViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 14, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: row.name))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(row.description)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    statusLine(for: row)
                }

                Spacer(minLength: 8)

                actionButton(for: row)
            }
        }
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
    private func statusLine(for row: PickyExtensionsSectionViewModel.Row) -> some View {
        switch row.status {
        case .installed:
            Text("status.extensions.state.installed")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.success)
        case .outdated:
            Text("status.extensions.state.outdated")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        case .legacySymlink:
            Text("status.extensions.state.legacySymlink")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .developerOverride(let target):
            Text(L10n.t("status.extensions.state.developerOverride", target))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .notInstalled:
            Text("status.extensions.state.notInstalled")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        case .conflict(let reason):
            Text(L10n.t("status.extensions.state.conflict", reason))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.destructiveText)
                .fixedSize(horizontal: false, vertical: true)
        case .bundleMissing:
            EmptyView()
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
