//
//  PickyInlineTerminalCardView.swift
//  Picky
//
//  Inline Pi TUI mode for the Pickle detail card.
//

import Combine
import SwiftTerm
import SwiftUI

@MainActor
final class PickyInlineTerminalSession: ObservableObject {
    let sessionID: String
    let title: String
    let sessionFilePath: String
    let cwd: String?
    let model: PickyTerminalModel
    let terminalView: PickySwiftTermView

    @Published private(set) var prepareError: String?

    private let baselineSnapshot: PickyTerminalSessionSnapshot?
    private var didPrepare = false
    private var didAttachTerminalView = false
    private var didRequestCloseSync = false

    init(
        sessionID: String,
        title: String,
        sessionFilePath: String,
        cwd: String?,
        baselineSnapshot: PickyTerminalSessionSnapshot?,
        fontScalePersister: PickyTerminalFontScalePersister
    ) {
        self.sessionID = sessionID
        self.title = title
        self.sessionFilePath = sessionFilePath
        self.cwd = cwd
        self.baselineSnapshot = baselineSnapshot
        self.model = PickyTerminalModel(
            title: title,
            sessionFilePath: sessionFilePath,
            cwd: cwd,
            fontScalePersister: fontScalePersister
        )
        self.terminalView = PickySwiftTermView(frame: .zero)
        self.terminalView.autoresizingMask = [.width, .height]
        self.terminalView.configurePickyAppearance(fontScale: model.fontScale)
    }

    func prepareIfNeeded() {
        guard !didPrepare else { return }
        didPrepare = true
        do {
            try model.prepare()
        } catch {
            prepareError = error.localizedDescription
        }
    }

    func attachIfNeeded() {
        guard prepareError == nil else { return }
        guard !didAttachTerminalView else { return }
        didAttachTerminalView = true
        model.attach(terminalView)
    }

    func closeAndScheduleSync(_ sync: @escaping @MainActor (_ baselineSnapshot: PickyTerminalSessionSnapshot?) -> Void) {
        guard !didRequestCloseSync else { return }
        didRequestCloseSync = true
        model.scheduleSyncOnExit { [baselineSnapshot] in
            sync(baselineSnapshot)
        }
        model.close()
    }
}

@MainActor
struct PickyInlineTerminalCardView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    let session: PickySessionListViewModel.SessionCard
    let contentWidth: CGFloat
    var isCommandShortcutHintVisible = false
    var onArchiveSession: (String) -> Void = { _ in }

    var body: some View {
        if let terminalSession = viewModel.inlineTerminalSession(for: session) {
            PickyInlineTerminalSessionView(
                viewModel: viewModel,
                session: session,
                terminalSession: terminalSession,
                contentWidth: contentWidth,
                isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                onArchiveSession: onArchiveSession
            )
        } else {
            missingSessionView
        }
    }

    private var missingSessionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("hud.inlineTerminal.unavailable.title")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("hud.inlineTerminal.unavailable.body")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
            Button("Back to Chat") {
                viewModel.disableInlineTerminalMode(sessionID: session.id)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: contentWidth, alignment: .topLeading)
    }
}

@MainActor
private struct PickyInlineTerminalSessionView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var terminalSession: PickyInlineTerminalSession
    let contentWidth: CGFloat
    let isCommandShortcutHintVisible: Bool
    var onArchiveSession: (String) -> Void = { _ in }
    @State private var attachmentID = UUID().uuidString

    private var isActiveAttachment: Bool {
        viewModel.isInlineTerminalAttachmentActive(sessionID: session.id, attachmentID: attachmentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            terminalBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.success)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(PickyHUDTypography.title)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text("hud.inlineTerminal.tab.tui")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.success)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule(style: .continuous).fill(DS.Colors.success.opacity(0.14)))
                        .overlay(Capsule(style: .continuous).stroke(DS.Colors.success.opacity(0.42), lineWidth: 0.6))
                }
                PickyInlineTerminalStatusLine(
                    model: terminalSession.model,
                    prepareError: terminalSession.prepareError
                )
            }
            Spacer(minLength: 8)
            Button {
                viewModel.disableInlineTerminalMode(sessionID: session.id)
            } label: {
                HStack(spacing: 5) {
                    Text("hud.inlineTerminal.tab.chat")
                    shortcutBadge("T")
                        .opacity(isCommandShortcutHintVisible ? 1 : 0)
                        .scaleEffect(isCommandShortcutHintVisible ? 1 : 0.88, anchor: .center)
                }
                .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
            }
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.borderless)
            .help("Return to the SwiftUI chat and composer (⌘T)")

            Menu {
                PickyConversationMenu(
                    session: session,
                    viewModel: viewModel,
                    onArchive: { onArchiveSession(session.id) }
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .frame(width: 18, height: 18)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Terminal mode menu")
        }
        .frame(minHeight: 26, alignment: .center)
    }

    private func shortcutBadge(_ letter: String) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: "command")
                .font(.system(size: 6.5, weight: .bold))
            Text(letter)
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 4.5)
        .frame(height: 15)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).fill(DS.Colors.surface1.opacity(0.70)))
        .overlay(Capsule(style: .continuous).strokeBorder(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.7))
        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1.5)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var terminalBody: some View {
        if !isActiveAttachment {
            inactiveTerminalPlaceholder
        } else if let prepareError = terminalSession.prepareError {
            VStack(alignment: .leading, spacing: 8) {
                Text("hud.inlineTerminal.failed.title")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(prepareError)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textSelection(.enabled)
                Button("Back to Chat") {
                    viewModel.disableInlineTerminalMode(sessionID: session.id)
                }
                .buttonStyle(.borderless)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface2.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        } else {
            PickyInlineSwiftTermViewRepresentable(terminalSession: terminalSession)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }

    private var inactiveTerminalPlaceholder: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Text("hud.inlineTerminal.singleton.title")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text("hud.inlineTerminal.singleton.body")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("Show This TUI") {
                viewModel.activateInlineTerminalAttachment(sessionID: session.id, attachmentID: attachmentID)
            }
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.borderless)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface2.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
    }

    private func handleAppear() {
        terminalSession.prepareIfNeeded()
        viewModel.activateInlineTerminalAttachment(sessionID: session.id, attachmentID: attachmentID)
        viewModel.endHoveredVoiceFollowUp(sessionID: session.id)
    }

    private func handleDisappear() {
        viewModel.releaseInlineTerminalAttachment(sessionID: session.id, attachmentID: attachmentID)
    }
}

private struct PickyInlineTerminalStatusLine: View {
    @ObservedObject var model: PickyTerminalModel
    let prepareError: String?

    var body: some View {
        Text(prepareError ?? model.statusText)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(prepareError == nil ? DS.Colors.textSecondary : DS.Colors.destructiveText)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct PickyInlineSwiftTermViewRepresentable: NSViewRepresentable {
    @ObservedObject var terminalSession: PickyInlineTerminalSession

    func makeCoordinator() -> PickySwiftTermViewRepresentable.Coordinator {
        PickySwiftTermViewRepresentable.Coordinator(model: terminalSession.model)
    }

    func makeNSView(context: Context) -> PickySwiftTermView {
        let terminalView = terminalSession.terminalView
        terminalView.processDelegate = context.coordinator
        terminalView.configurePickyAppearance(fontScale: terminalSession.model.fontScale)
        terminalSession.attachIfNeeded()
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ terminalView: PickySwiftTermView, context: Context) {
        terminalView.processDelegate = context.coordinator
        terminalView.applyFontScale(terminalSession.model.fontScale)
        if terminalView.window?.firstResponder == nil {
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }
    }
}
