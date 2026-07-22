//
//  PickySessionExtendedTerminalView.swift
//  Picky
//
//  Local shell terminal panel attached below a Pickle HUD card. Branded as
//  the "Extended terminal" in the UI and matched by the `Cmd + E` shortcut,
//  to distinguish it from the inline terminal mode (`Cmd + T`) that swaps
//  the card body itself into a Pi TUI.
//

import AppKit
import Combine
import SwiftTerm
import SwiftUI

enum PickyShellTerminalCommand {
    static func resolvedShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let shell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isExecutable(shell) { return shell }
        if isExecutable("/bin/bash") { return "/bin/bash" }
        return "/bin/sh"
    }

    static func workingDirectory(from cwd: String?) -> String {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = trimmed.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : NSString(string: trimmed).standardizingPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
            return candidate
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func makeEnvironment(_ baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var environment = baseEnvironment
        let existingPATH = environment["PATH"] ?? ""
        environment["PATH"] = existingPATH.isEmpty ? defaultPATH : "\(defaultPATH):\(existingPATH)"
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Picky"
        if environment["LANG"]?.isEmpty ?? true {
            environment["LANG"] = "en_US.UTF-8"
        }
        if environment["LC_CTYPE"]?.isEmpty ?? true {
            environment["LC_CTYPE"] = "en_US.UTF-8"
        }
        return environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    private static func isExecutable(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static let defaultPATH = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")
}

@MainActor
final class PickyShellTerminalSession: ObservableObject {
    let sessionID: String
    let title: String
    let cwd: String?
    let model: PickyShellTerminalModel
    let terminalView: PickySwiftTermView

    init(
        sessionID: String,
        title: String,
        cwd: String?,
        fontScalePersister: PickyTerminalFontScalePersister
    ) {
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.model = PickyShellTerminalModel(
            title: title,
            cwd: cwd,
            fontScalePersister: fontScalePersister
        )
        self.terminalView = PickySwiftTermView(frame: .zero)
        self.terminalView.autoresizingMask = [.width, .height]
        self.terminalView.configurePickyAppearance(fontScale: model.fontScale)
    }

    func attach() {
        model.attach(terminalView)
    }

    func close() {
        model.close()
    }
}

@MainActor
final class PickyShellTerminalModel: ObservableObject, PickyTerminalProcessEventHandling {
    @Published private(set) var statusText: String
    @Published private(set) var fontScale: Double

    let title: String
    let cwd: String?

    private weak var terminalView: LocalProcessTerminalView?
    private var didStartProcess = false
    private(set) lazy var processDelegate = PickyTerminalProcessDelegate(handler: self)
    private let fontScalePersister: PickyTerminalFontScalePersister?

    init(
        title: String,
        cwd: String?,
        fontScalePersister: PickyTerminalFontScalePersister? = nil
    ) {
        self.title = title
        self.cwd = cwd
        self.fontScalePersister = fontScalePersister
        self.fontScale = PickyFontScales.clamped(fontScalePersister?.load() ?? PickyFontScales.defaults.terminal)
        self.statusText = "Ready in \(Self.compactPath(PickyShellTerminalCommand.workingDirectory(from: cwd)))"
    }

    func attach(_ terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        startProcessIfNeeded(in: terminalView)
    }

    func close() {
        terminalView?.terminate()
        terminalView = nil
        didStartProcess = false
        statusText = "Shell closed"
    }

    func processExited(exitCode: Int32?) {
        terminalView = nil
        didStartProcess = false
        if let exitCode {
            statusText = "Shell exited with code \(exitCode)"
        } else {
            statusText = "Shell exited"
        }
    }

    func updateTerminalTitle(_ terminalTitle: String) {
        guard !terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        statusText = "Shell in \(Self.compactPath(PickyShellTerminalCommand.workingDirectory(from: cwd)))"
    }

    private func startProcessIfNeeded(in terminalView: LocalProcessTerminalView) {
        guard !didStartProcess else { return }
        didStartProcess = true
        let shell = PickyShellTerminalCommand.resolvedShell()
        let workingDirectory = PickyShellTerminalCommand.workingDirectory(from: cwd)
        statusText = "\((shell as NSString).lastPathComponent) in \(Self.compactPath(workingDirectory))"
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: PickyShellTerminalCommand.makeEnvironment(),
            currentDirectory: workingDirectory
        )
    }

    private static func compactPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardizedPath = NSString(string: path).standardizingPath
        if standardizedPath == homePath { return "~" }
        if standardizedPath.hasPrefix(homePath + "/") {
            return "~" + String(standardizedPath.dropFirst(homePath.count))
        }
        return path
    }
}

struct PickySessionExtendedTerminalView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        PickySessionExtendedTerminalContentView(
            session: session,
            viewModel: viewModel,
            terminalSession: viewModel.shellTerminalSession(for: session),
            width: pickyHUDDetailWidth
        )
    }
}

private struct PickySessionExtendedTerminalContentView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    @ObservedObject var terminalSession: PickyShellTerminalSession
    let width: CGFloat
    @State private var attachmentID = UUID().uuidString

    private var isActiveAttachment: Bool {
        viewModel.isShellTerminalAttachmentActive(sessionID: session.id, attachmentID: attachmentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            terminalBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .frame(width: width, height: PickyHUDDockLayout.extendedTerminalHeight, alignment: .topLeading)
        .background(addonBackground)
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "terminal.fill")
                .pickyFont(size: 11.5, weight: .semibold)
                .foregroundColor(DS.Colors.successText)
            Text(verbatim: "Local Terminal")
                .pickyFont(size: 11.5, weight: .semibold)
                .foregroundColor(DS.Colors.textPrimary)
            Text(terminalSession.model.statusText)
                .font(PickyHUDTypography.minimumMonospaced)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(verbatim: "⌘E hide")
                .font(PickyHUDTypography.minimumMedium)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(height: 16, alignment: .center)
    }

    @ViewBuilder
    private var terminalBody: some View {
        if isActiveAttachment {
            PickyShellTerminalViewRepresentable(terminalSession: terminalSession)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
                )
        } else {
            inactiveTerminalPlaceholder
        }
    }

    private var inactiveTerminalPlaceholder: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .pickyFont(size: 19, weight: .semibold)
                .foregroundColor(DS.Colors.textTertiary)
            Text(verbatim: "Terminal is already visible in another HUD panel")
                .pickyFont(size: 11.5, weight: .semibold)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Button("Show This Terminal") {
                viewModel.activateShellTerminalAttachment(sessionID: session.id, attachmentID: attachmentID)
            }
            .pickyFont(size: 11, weight: .semibold)
            .buttonStyle(.borderless)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Colors.surface2.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
    }

    private func handleAppear() {
        viewModel.activateShellTerminalAttachment(sessionID: session.id, attachmentID: attachmentID)
        viewModel.endHoveredVoiceFollowUp(sessionID: session.id)
    }

    private func handleDisappear() {
        viewModel.releaseShellTerminalAttachment(sessionID: session.id, attachmentID: attachmentID)
    }

    private var addonBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
            .fill(DS.Colors.surface1.opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.5)
            )
    }
}

private struct PickyShellTerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var terminalSession: PickyShellTerminalSession

    func makeNSView(context: Context) -> PickySwiftTermView {
        let terminalView = terminalSession.terminalView
        terminalView.processDelegate = terminalSession.model.processDelegate
        terminalView.configurePickyAppearance(fontScale: terminalSession.model.fontScale)
        terminalSession.attach()
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ terminalView: PickySwiftTermView, context: Context) {
        terminalView.processDelegate = terminalSession.model.processDelegate
        terminalView.applyFontScale(terminalSession.model.fontScale)
        if terminalView.window?.firstResponder == nil {
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }
    }
}
