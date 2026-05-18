//
//  PickySessionNoteAddonView.swift
//  Picky
//
//  Lightweight local-only note panel attached to a Pickle HUD card.
//

import AppKit
import SwiftUI

struct PickySessionNoteAddonView: View {
    let sessionID: String
    @ObservedObject var viewModel: PickySessionListViewModel
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth
    @State private var isFocused: Bool = false
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if note.isEmpty {
                    Text("hud.sessionNote.placeholder")
                        .font(PickyHUDTypography.bodyCompact)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                PickyIMETextView(
                    text: $note,
                    isFocused: Binding(
                        get: { isFocused },
                        set: { isFocused = $0 }
                    ),
                    font: NSFont.systemFont(ofSize: PickyHUDTypography.Size.bodyCompact, weight: .regular),
                    textColor: NSColor(DS.Colors.textPrimary),
                    textContainerInsetHeight: 3
                )
                .padding(5)
                .onChange(of: note) { _, newValue in
                    viewModel.updateSessionNote(newValue, sessionID: sessionID)
                }
            }
            .frame(height: PickyHUDDockLayout.noteAddonEditorHeight)
            .background(editorBackground)
        }
        .padding(12)
        .frame(
            width: pickyHUDDetailWidth,
            height: PickyHUDDockLayout.noteAddonHeight,
            alignment: .topLeading
        )
        .background(addonBackground)
        .onAppear {
            note = viewModel.persistedSessionNote(for: sessionID)
            requestEditorFocus()
        }
        .onDisappear {
            viewModel.updateSessionNote(note, sessionID: sessionID)
        }
        .onChange(of: sessionID) { _, newSessionID in
            note = viewModel.persistedSessionNote(for: newSessionID)
        }
    }

    private func requestEditorFocus() {
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DS.Colors.surface2.opacity(0.38))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.5)
            )
    }

    private var addonBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DS.Colors.surface1.opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.5)
            )
    }
}
