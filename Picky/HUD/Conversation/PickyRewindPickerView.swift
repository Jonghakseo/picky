//
//  PickyRewindPickerView.swift
//  Picky
//
//  Compact HUD sheet for choosing a Pi session user-message entry to rewind to.
//

import SwiftUI

struct PickyRewindPickerView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var targets: [PickyRewindTarget] = []
    @State private var selectedTargetID: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var currentTargetID: String? { targets.last?.entryId }
    private var selectedTarget: PickyRewindTarget? {
        guard let selectedTargetID else { return nil }
        return targets.first { $0.entryId == selectedTargetID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            footer
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .background(DS.Colors.surface1)
        .task { await loadTargets() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("hud.rewind.title")
                .font(PickyHUDTypography.title)
                .foregroundColor(DS.Colors.textPrimary)
            Text(session.title)
                .font(PickyHUDTypography.supporting)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
        } else if let errorMessage {
            Text(errorMessage)
                .font(PickyHUDTypography.supporting)
                .foregroundColor(DS.Colors.destructiveText)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
        } else if targets.isEmpty {
            Text("hud.rewind.empty")
                .font(PickyHUDTypography.supporting)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(targets) { target in
                        targetRow(target)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("hud.rewind.cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("hud.rewind.confirm") {
                confirmSelection()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedTarget == nil)
        }
    }

    private func targetRow(_ target: PickyRewindTarget) -> some View {
        let isCurrent = target.entryId == currentTargetID
        let isSelected = target.entryId == selectedTargetID

        return Button {
            guard !isCurrent else { return }
            selectedTargetID = target.entryId
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 5) {
                    Text(target.text)
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(isCurrent ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if let createdAt = target.createdAt {
                            Text(Self.relativeTimestamp(for: createdAt))
                                .font(PickyHUDTypography.meta)
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        if isCurrent {
                            Text("hud.rewind.currentPosition")
                                .font(PickyHUDTypography.meta)
                                .foregroundColor(DS.Colors.accentText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(DS.Colors.accentSubtle.opacity(0.45))
                                )
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowFill(isSelected: isSelected, isCurrent: isCurrent))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(rowStroke(isSelected: isSelected), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    private func rowFill(isSelected: Bool, isCurrent: Bool) -> Color {
        if isSelected { return DS.Colors.accentSubtle.opacity(0.24) }
        if isCurrent { return DS.Colors.surface2.opacity(0.45) }
        return DS.Colors.surface2.opacity(0.75)
    }

    private func rowStroke(isSelected: Bool) -> Color {
        isSelected ? DS.Colors.accentText.opacity(0.35) : DS.Colors.borderSubtle.opacity(0.55)
    }

    @MainActor
    private func loadTargets() async {
        isLoading = true
        errorMessage = nil
        selectedTargetID = nil
        do {
            targets = try await viewModel.loadRewindTargets(sessionID: session.id)
        } catch {
            targets = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func confirmSelection() {
        guard let selectedTarget else { return }
        let sessionID = session.id
        let entryID = selectedTarget.entryId
        dismiss()
        Task { await viewModel.rewind(sessionID: sessionID, toEntry: entryID) }
    }

    private static func relativeTimestamp(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
