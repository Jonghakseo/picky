//
//  PickyDockGroupCreatorView.swift
//  Picky
//
//  Group-creation popover content. Replaces the previous "create empty
//  group, then inline-rename" flow with a single step that captures the
//  group name and any initial member Pickles up-front.
//

import SwiftUI

struct PickyDockGroupCreatorView: View {
    /// All Pickles currently visible in the dock universe, in the dock's
    /// render order. The creator lists them with checkboxes so the user can
    /// hand-pick which ones land in the new group.
    let availableSessions: [PickySessionListViewModel.SessionCard]
    /// Accent color the new group will adopt — surfaced as a small swatch
    /// in the header so the user knows which color rotation they'll land
    /// on. Always derived from the live group count so the swatch matches
    /// whatever color the layout would actually assign on save.
    let suggestedColor: PickyDockGroupColor
    /// Fired when the user confirms. Caller is responsible for dismissing
    /// any wrapping popover/sheet.
    let onCreate: (_ name: String, _ memberSessionIDs: [String]) -> Void
    /// Fired when the user cancels or hits Escape. Caller decides whether
    /// to dismiss or fall back to the previous popover state.
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var selectedMemberIDs: Set<String> = []
    @FocusState private var isNameFieldFocused: Bool

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            nameField
            membersSection
            footer
        }
        .padding(14)
        .frame(width: 286)
        .onAppear {
            // Pull keyboard focus to the name field so the user can type
            // immediately without an extra click — matches the prior
            // inline-rename behavior the dialog replaces.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isNameFieldFocused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(suggestedColor.accent)
                .frame(width: 10, height: 10)
            Text("New group")
                .pickyFont(size: 14, weight: .medium)
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name")
                .pickyFont(size: 11, weight: .medium)
                .foregroundStyle(DS.Colors.textSecondary)
            TextField("e.g. creatrip-web", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFieldFocused)
                .onSubmit {
                    if canCreate {
                        onCreate(name, Array(selectedMembersInRenderOrder))
                    }
                }
        }
    }

    @ViewBuilder
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Include Pickles")
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                if !selectedMemberIDs.isEmpty {
                    Text("\(selectedMemberIDs.count) selected")
                        .pickyFont(size: 11)
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }
            if availableSessions.isEmpty {
                Text("No Pickles to include yet. You can create the group now and drag Pickles in later.")
                    .pickyFont(size: 12)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(availableSessions, id: \.id) { session in
                            memberRow(for: session)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private func memberRow(for session: PickySessionListViewModel.SessionCard) -> some View {
        let isSelected = selectedMemberIDs.contains(session.id)
        return Button {
            if isSelected {
                selectedMemberIDs.remove(session.id)
            } else {
                selectedMemberIDs.insert(session.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.title.isEmpty ? "Untitled Pickle" : session.title)
                        .pickyFont(size: 12, weight: .medium)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if let cwd = session.compactCwdDescription {
                        Text(cwd)
                            .pickyFont(size: 10)
                            .foregroundStyle(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle.opacity(0.6) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isSelected ? "Remove" : "Add") \(session.title) \(isSelected ? "from" : "to") group")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Create") {
                onCreate(name, Array(selectedMembersInRenderOrder))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
    }

    /// Project the user's selection back onto the dock's render order so
    /// the group's member array preserves what the dock already showed —
    /// prevents surprise reordering when a session that lived in the top
    /// slot ends up at the bottom of the new group just because the user
    /// happened to tick its checkbox last.
    private var selectedMembersInRenderOrder: [String] {
        availableSessions
            .map(\.id)
            .filter { selectedMemberIDs.contains($0) }
    }
}
