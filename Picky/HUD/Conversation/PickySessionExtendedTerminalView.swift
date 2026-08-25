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

    private let processHost: (any PickyTerminalProcessHosting)?

    init(
        sessionID: String,
        title: String,
        cwd: String?,
        fontScalePersister: PickyTerminalFontScalePersister,
        processHost: (any PickyTerminalProcessHosting)? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.processHost = processHost
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
        model.attachProcessHost(processHost ?? terminalView)
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

    private weak var terminalView: (any PickyTerminalProcessHosting)?
    private var didStartProcess = false
    private var isClosed = false
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

    /// The process host is an adapter boundary so lifecycle behavior can be
    /// characterized without spawning a real shell.
    func attachProcessHost(_ terminalView: any PickyTerminalProcessHosting) {
        guard !isClosed else {
            terminalView.processDelegate = nil
            return
        }
        terminalView.processDelegate = processDelegate
        self.terminalView = terminalView
        startProcessIfNeeded(in: terminalView)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        guard didStartProcess, let terminalView else {
            self.terminalView = nil
            statusText = "Shell closed"
            return
        }
        terminalView.processDelegate = nil
        terminalView.terminatePickyProcess()
        self.terminalView = nil
        statusText = "Shell closed"
    }

    func processExited(exitCode: Int32?) {
        terminalView?.processDelegate = nil
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

    private func startProcessIfNeeded(in terminalView: any PickyTerminalProcessHosting) {
        guard !didStartProcess, !isClosed else { return }
        didStartProcess = true
        let shell = PickyShellTerminalCommand.resolvedShell()
        let workingDirectory = PickyShellTerminalCommand.workingDirectory(from: cwd)
        statusText = "\((shell as NSString).lastPathComponent) in \(Self.compactPath(workingDirectory))"
        terminalView.startPickyProcess(
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

enum PickySessionExtendedTerminalFocusPolicy {
    static func shouldRequestFocus(isFocusEligible: Bool) -> Bool { isFocusEligible }

    static func terminalOwnsFirstResponder(_ firstResponder: NSResponder?, terminalView: NSView) -> Bool {
        guard let responderView = firstResponder as? NSView else { return false }
        return responderView === terminalView || responderView.isDescendant(of: terminalView)
    }

    @discardableResult
    static func resignTerminalFocusIfIneligible(_ terminalView: NSView, isFocusEligible: Bool) -> Bool {
        guard !isFocusEligible,
              let window = terminalView.window,
              terminalOwnsFirstResponder(window.firstResponder, terminalView: terminalView)
        else { return false }
        return window.makeFirstResponder(nil)
    }
}

struct PickySessionExtendedTerminalView: View {
    /// This panel owns a stable session-store dependency and receives only
    /// terminal commands; it must not observe the global session façade.
    let sessionStore: PickySessionStore
    let commands: any PickySessionCommands
    var height: CGFloat = PickyHUDUtilityPanelPolicy.defaultHeight
    var showsPanelChrome = true
    var isFocusEligible = true

    var body: some View {
        PickySessionExtendedTerminalContentView(
            sessionID: sessionStore.sessionID,
            commands: commands,
            attachmentStore: commands.shellTerminalAttachmentStore,
            terminalSession: commands.shellTerminalSession(sessionID: sessionStore.sessionID),
            height: height,
            showsPanelChrome: showsPanelChrome,
            isFocusEligible: isFocusEligible
        )
    }
}

private struct PickySessionExtendedTerminalContentView: View {
    let sessionID: String
    let commands: any PickySessionCommands
    let attachmentStore: PickyTerminalAttachmentStore
    @ObservedObject var terminalSession: PickyShellTerminalSession
    let height: CGFloat
    let showsPanelChrome: Bool
    let isFocusEligible: Bool
    @State private var attachmentID = UUID().uuidString

    private var isActiveAttachment: Bool {
        attachmentStore.isActive(sessionID: sessionID, attachmentID: attachmentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            terminalBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        .background {
            if showsPanelChrome {
                addonBackground
            }
        }
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
            PickyShellTerminalViewRepresentable(terminalSession: terminalSession, isFocusEligible: isFocusEligible)
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
                commands.activateShellTerminalAttachment(sessionID: sessionID, attachmentID: attachmentID)
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
        commands.activateShellTerminalAttachment(sessionID: sessionID, attachmentID: attachmentID)
        commands.endHoveredVoiceFollowUp(sessionID: sessionID)
    }

    private func handleDisappear() {
        commands.releaseShellTerminalAttachment(sessionID: sessionID, attachmentID: attachmentID)
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
    let isFocusEligible: Bool

    final class Coordinator {
        var isFocusEligible = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PickySwiftTermView {
        let terminalView = terminalSession.terminalView
        terminalView.processDelegate = terminalSession.model.processDelegate
        terminalView.configurePickyAppearance(fontScale: terminalSession.model.fontScale)
        terminalSession.attach()
        context.coordinator.isFocusEligible = isFocusEligible
        requestFocusIfEligible(terminalView, coordinator: context.coordinator)
        return terminalView
    }

    func updateNSView(_ terminalView: PickySwiftTermView, context: Context) {
        terminalView.processDelegate = terminalSession.model.processDelegate
        terminalView.applyFontScale(terminalSession.model.fontScale)
        context.coordinator.isFocusEligible = isFocusEligible
        PickySessionExtendedTerminalFocusPolicy.resignTerminalFocusIfIneligible(
            terminalView,
            isFocusEligible: isFocusEligible
        )
        requestFocusIfEligible(terminalView, coordinator: context.coordinator)
    }

    private func requestFocusIfEligible(_ terminalView: PickySwiftTermView, coordinator: Coordinator) {
        guard PickySessionExtendedTerminalFocusPolicy.shouldRequestFocus(isFocusEligible: isFocusEligible) else { return }
        DispatchQueue.main.async {
            guard coordinator.isFocusEligible, terminalView.window?.firstResponder == nil else { return }
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }
}
