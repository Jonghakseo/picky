//
//  PickyConversationCardView.swift
//  Picky
//
//  Core conversation-style side-agent card container.
//

import SwiftUI
import UniformTypeIdentifiers

struct PickyConversationCardView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    let session: PickySessionListViewModel.SessionCard
    @State private var droppedFilePaths: [String] = []
    @State private var isFileDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PickyConversationHeaderView(viewModel: viewModel, session: session)
            PickyConversationContextLineView(session: session)
            PickyConversationListView(session: session, viewModel: viewModel)
            PickyConversationComposerView(
                session: session,
                viewModel: viewModel,
                droppedFilePaths: $droppedFilePaths,
                isFileDropTargeted: isFileDropTargeted
            )
        }
        .frame(width: PickyHUDDockLayout.detailContentWidth, alignment: .topLeading)
        .padding(.horizontal, PickyHUDDockLayout.detailHorizontalPadding)
        .padding(.vertical, 12)
        .frame(width: PickyHUDDockLayout.detailWidth)
        .frame(minHeight: 320, maxHeight: 1080, alignment: .top)
        .background(cardBackground)
        .background(reportKeyboardShortcut)
        .contentShape(Rectangle())
        .onDrop(of: [PickyConversationFileDrop.fileURLType], isTargeted: $isFileDropTargeted, perform: handleFileDrop)
        .onHover(perform: updateVoiceFollowUpHover)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter(PickyConversationFileDrop.acceptsFileURL)
        guard !fileProviders.isEmpty else { return false }

        Task {
            let paths = await PickyConversationFileDrop.filePaths(from: fileProviders)
            guard !paths.isEmpty else { return }
            await MainActor.run {
                droppedFilePaths.append(contentsOf: paths)
            }
        }
        return true
    }

    func updateVoiceFollowUpHover(_ hovering: Bool) {
        if hovering {
            viewModel.beginHoveredVoiceFollowUp(sessionID: session.id)
        } else {
            viewModel.endHoveredVoiceFollowUp(sessionID: session.id)
        }
    }

    /// Hidden button that binds ⌘R at card/window scope. Menu keyboard shortcuts are
    /// only reliable while the menu is open; this keeps "Open report" available while
    /// the HUD card itself is focused.
    private var reportKeyboardShortcut: some View {
        Button("Open report") {
            Task { try? await viewModel.openReport(sessionID: session.id) }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!session.canOpenMarkdownReport)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DS.Colors.surface1.opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(cardBorderColor, lineWidth: isFileDropTargeted ? 1.3 : 1)
            )
            .shadow(color: .black.opacity(PickyHUDExpansion.cardShadowOpacity), radius: PickyHUDExpansion.cardShadowRadius, y: PickyHUDExpansion.cardShadowYOffset)
    }

    private var cardBorderColor: Color {
        isFileDropTargeted ? DS.Colors.accentText.opacity(0.85) : statusColor.opacity(0.58)
    }

    private var statusColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .completed:
            return DS.Colors.success
        case .waiting_for_input:
            return DS.Colors.warning
        case .failed:
            return DS.Colors.destructiveText
        case .blocked:
            return DS.Colors.warningText
        case .queued, .cancelled:
            return DS.Colors.textTertiary
        }
    }
}

private enum PickyConversationFileDrop {
    static let fileURLType = UTType.fileURL.identifier

    static func acceptsFileURL(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(fileURLType)
    }

    static func filePaths(from providers: [NSItemProvider]) async -> [String] {
        var paths: [String] = []
        for provider in providers {
            if let path = await filePath(from: provider) {
                paths.append(path)
            }
        }
        return paths
    }

    private static func filePath(from provider: NSItemProvider) async -> String? {
        guard acceptsFileURL(provider) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: filePath(fromDropItem: item))
            }
        }
    }

    private static func filePath(fromDropItem item: Any?) -> String? {
        if let url = item as? URL, url.isFileURL { return url.path }
        if let url = item as? NSURL, url.isFileURL { return url.path }
        if let string = item as? String { return filePath(fromDropString: string) }
        if let string = item as? NSString { return filePath(fromDropString: string as String) }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                return url.path
            }
            if let string = String(data: data, encoding: .utf8) {
                return filePath(fromDropString: string)
            }
        }
        return nil
    }

    private static func filePath(fromDropString string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        if let url = URL(string: trimmed), url.isFileURL { return url.path }
        if trimmed.hasPrefix("/") { return trimmed }
        return nil
    }
}
