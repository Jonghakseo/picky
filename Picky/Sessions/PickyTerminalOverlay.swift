//
//  PickyTerminalOverlay.swift
//  Picky
//
//  In-app Pi terminal overlay backed by SwiftTerm.
//

import AppKit
import Combine
import Foundation
import SwiftTerm
import SwiftUI

@MainActor
protocol PickyTerminalOverlayPresenting: AnyObject {
    func openTerminal(
        sessionID: String,
        title: String,
        sessionFilePath: String,
        cwd: String?,
        onClose: @escaping @MainActor () -> Void
    ) throws
}

enum PickyTerminalOverlayError: LocalizedError, Equatable {
    case alreadyRunning
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Pi terminal is already open for this session."
        case .failedToStart(let message):
            return "Failed to open Pi terminal: \(message)"
        }
    }
}

enum PickyPiTerminalCommand {
    static func makeCliResumeCommand(sessionFilePath: String, cwd: String?) -> String {
        let workingDirectory = workingDirectory(from: cwd)
        return "cd \(shellQuoted(workingDirectory)) && pi --session \(shellQuoted(sessionFilePath))"
    }

    static func makeOverlayCommand(sessionFilePath: String, cwd: String?) -> String {
        let workingDirectory = workingDirectory(from: cwd)
        return "export PATH=\(shellQuoted(defaultPATH)):$PATH && cd \(shellQuoted(workingDirectory)) && exec pi --session \(shellQuoted(sessionFilePath))"
    }

    static func makeOverlayEnvironment(_ baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
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

    static func workingDirectory(from cwd: String?) -> String {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedCwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : trimmedCwd
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
final class PickyTerminalOverlayPresenter: PickyTerminalOverlayPresenting {
    static let shared = PickyTerminalOverlayPresenter()

    private struct TerminalRecord {
        let panel: NSPanel
        let model: PickyTerminalModel
        let delegate: PickyTerminalPanelDelegate
    }

    private var records: [String: TerminalRecord] = [:]

    private init() {}

    func openTerminal(
        sessionID: String,
        title: String,
        sessionFilePath: String,
        cwd: String?,
        onClose: @escaping @MainActor () -> Void
    ) throws {
        if let existing = records[sessionID] {
            NSApp.activate(ignoringOtherApps: true)
            existing.panel.orderFrontRegardless()
            existing.panel.makeKey()
            return
        }

        let model = PickyTerminalModel(
            title: title,
            sessionFilePath: sessionFilePath,
            cwd: cwd
        )
        try model.prepare()

        let panel = PickyTerminalPanel(
            contentRect: targetFrame(),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pi Terminal — \(title)"
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.98)
        panel.minSize = NSSize(width: 680, height: 420)

        let hostingView = NSHostingView(rootView: PickyTerminalOverlayView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        let delegate = PickyTerminalPanelDelegate { [weak self, weak model, weak panel] in
            model?.close()
            onClose()
            if let panel {
                self?.remove(panel: panel)
            }
        }
        panel.delegate = delegate
        records[sessionID] = TerminalRecord(panel: panel, model: model, delegate: delegate)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func remove(panel: NSPanel) {
        records = records.filter { $0.value.panel !== panel }
    }

    private func targetFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(CGFloat(980), visibleFrame.width - 48)
        let height = min(CGFloat(640), visibleFrame.height - 48)
        return NSRect(
            x: visibleFrame.maxX - width - 24,
            y: visibleFrame.maxY - height - 24,
            width: width,
            height: height
        )
    }
}

final class PickyTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PickyTerminalPanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void
    private var didClose = false

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        MainActor.assumeIsolated {
            onClose()
        }
    }
}

@MainActor
final class PickyTerminalModel: ObservableObject {
    @Published private(set) var statusText = "Starting pi --session…"

    let title: String
    let sessionFilePath: String
    let cwd: String?

    private weak var terminalView: LocalProcessTerminalView?
    private var didStartProcess = false

    init(title: String, sessionFilePath: String, cwd: String?) {
        self.title = title
        self.sessionFilePath = sessionFilePath
        self.cwd = cwd
    }

    func prepare() throws {
        guard FileManager.default.fileExists(atPath: sessionFilePath) else {
            throw PickyTerminalOverlayError.failedToStart("Session file does not exist: \(sessionFilePath)")
        }
        statusText = "Attached to \(compactPath(sessionFilePath))"
    }

    func attach(_ terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        startProcessIfNeeded(in: terminalView)
    }

    func close() {
        terminalView?.terminate()
        terminalView = nil
        didStartProcess = false
    }

    func processExited(exitCode: Int32?) {
        terminalView = nil
        didStartProcess = false
        if let exitCode {
            statusText = "Pi terminal exited with code \(exitCode). Close to sync the session card."
        } else {
            statusText = "Pi terminal closed. Close to sync the session card."
        }
    }

    func updateTerminalTitle(_ terminalTitle: String) {
        guard !terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        statusText = "Attached to \(compactPath(sessionFilePath))"
    }

    private func startProcessIfNeeded(in terminalView: LocalProcessTerminalView) {
        guard !didStartProcess else { return }
        didStartProcess = true
        let command = PickyPiTerminalCommand.makeOverlayCommand(sessionFilePath: sessionFilePath, cwd: cwd)
        terminalView.startProcess(
            executable: "/bin/zsh",
            args: ["-lc", command],
            environment: PickyPiTerminalCommand.makeOverlayEnvironment(),
            currentDirectory: PickyPiTerminalCommand.workingDirectory(from: cwd)
        )
    }

    private func compactPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardizedPath = NSString(string: path).standardizingPath
        if standardizedPath.hasPrefix(homePath + "/") {
            return "~" + String(standardizedPath.dropFirst(homePath.count))
        }
        return path
    }
}

struct PickyTerminalOverlayView: View {
    @ObservedObject var model: PickyTerminalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.green.opacity(0.92))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.94))
                        .lineLimit(1)
                    Text(model.statusText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.white.opacity(0.54))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("⌘W / close syncs once")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.42))
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            PickySwiftTermViewRepresentable(model: model)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(Color(red: 0.035, green: 0.038, blue: 0.045).opacity(0.98))
    }
}

struct PickySwiftTermViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: PickyTerminalModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> PickySwiftTermView {
        let terminalView = PickySwiftTermView(frame: .zero)
        terminalView.processDelegate = context.coordinator
        terminalView.autoresizingMask = [.width, .height]
        terminalView.configurePickyAppearance()
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        model.attach(terminalView)
        return terminalView
    }

    func updateNSView(_ terminalView: PickySwiftTermView, context: Context) {
        terminalView.processDelegate = context.coordinator
        if terminalView.window?.firstResponder == nil {
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var model: PickyTerminalModel?

        init(model: PickyTerminalModel) {
            self.model = model
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor [weak self] in
                self?.model?.updateTerminalTitle(title)
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor [weak self] in
                self?.model?.processExited(exitCode: exitCode)
            }
        }
    }
}

final class PickySwiftTermView: LocalProcessTerminalView {
    func configurePickyAppearance() {
        font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        nativeForegroundColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        nativeBackgroundColor = NSColor(calibratedRed: 0.02, green: 0.024, blue: 0.03, alpha: 1)
        layer?.backgroundColor = nativeBackgroundColor.cgColor
        backspaceSendsControlH = false
        caretViewTracksFocus = false
        antiAliasCustomBlockGlyphs = false
        postsFrameChangedNotifications = true
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = terminalInputString(from: string), shouldBypassKittyKeyboardForIMECommit(text) {
            applyTerminalReplacementIfNeeded(for: string, replacementRange: replacementRange)
            super.unmarkText()
            send(txt: text)
            return
        }

        applyTerminalReplacementIfNeeded(for: string, replacementRange: replacementRange)
        super.insertText(string, replacementRange: replacementRange)
    }

    private func shouldBypassKittyKeyboardForIMECommit(_ text: String) -> Bool {
        guard !terminal.keyboardEnhancementFlags.isEmpty else { return false }
        guard text.unicodeScalars.contains(where: { $0.value > 0x7f }) else { return false }
        return !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    @discardableResult
    private func applyTerminalReplacementIfNeeded(for string: Any, replacementRange: NSRange) -> Bool {
        guard shouldApplyTerminalReplacement(for: string, replacementRange: replacementRange) else { return false }
        send(Array(repeating: backspaceSendsControlH ? UInt8(8) : UInt8(0x7f), count: replacementRange.length))
        return true
    }

    private func shouldApplyTerminalReplacement(for string: Any, replacementRange: NSRange) -> Bool {
        guard replacementRange.location != NSNotFound,
              replacementRange.length > 0,
              terminalInputString(from: string)?.isEmpty == false else {
            return false
        }

        // Korean IME on macOS may commit intermediate jamo/syllables via insertText
        // with a replacementRange. SwiftTerm's default insertText ignores that range,
        // so the terminal receives leaked raw jamo. A terminal cannot mutate text
        // storage directly, but when the replacement is immediately before the caret
        // we can emulate the AppKit replacement by sending DEL before the committed text.
        let selectedRange = super.selectedRange()
        guard selectedRange.location == NSNotFound else {
            return replacementRange.location + replacementRange.length <= selectedRange.location
        }
        return true
    }

    private func terminalInputString(from value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let attributed as NSAttributedString:
            return attributed.string
        default:
            return nil
        }
    }
}

struct PickyTerminalSessionSnapshot: Equatable {
    var lastUserText: String?
    var lastAssistantText: String?

    var isEmpty: Bool {
        lastUserText == nil && lastAssistantText == nil
    }
}

protocol PickyTerminalSessionSyncing {
    func snapshot(sessionFilePath: String) throws -> PickyTerminalSessionSnapshot
}

struct PickyPiSessionFileSyncer: PickyTerminalSessionSyncing {
    func snapshot(sessionFilePath: String) throws -> PickyTerminalSessionSnapshot {
        let data = try Data(contentsOf: URL(fileURLWithPath: sessionFilePath))
        guard let text = String(data: data, encoding: .utf8) else { return PickyTerminalSessionSnapshot() }
        let entries = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> PiSessionMessageEntry? in
                guard let lineData = String(line).data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(PiSessionMessageEntry.self, from: lineData)
            }
            .filter { $0.type == "message" && $0.message != nil }

        let activePath = activeMessagePath(from: entries)
        let lastUserText = activePath.reversed().first { $0.message?.role == "user" }?.message?.plainText.nonEmptyTrimmed
        let lastAssistantText = activePath.reversed().first { $0.message?.role == "assistant" }?.message?.plainText.nonEmptyTrimmed
        return PickyTerminalSessionSnapshot(lastUserText: lastUserText, lastAssistantText: lastAssistantText)
    }

    private func activeMessagePath(from entries: [PiSessionMessageEntry]) -> [PiSessionMessageEntry] {
        guard var current = entries.last else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.id.map { ($0, entry) }
        })
        var path: [PiSessionMessageEntry] = []
        var seen = Set<String>()
        while true {
            path.append(current)
            guard let parentId = current.parentId,
                  !seen.contains(parentId),
                  let parent = byId[parentId] else { break }
            seen.insert(parentId)
            current = parent
        }
        return path.reversed()
    }
}

private struct PiSessionMessageEntry: Decodable {
    let type: String
    let id: String?
    let parentId: String?
    let message: PiSessionMessage?
}

private struct PiSessionMessage: Decodable {
    let role: String
    let content: PiSessionMessageContent

    var plainText: String {
        content.plainText
    }
}

private enum PiSessionMessageContent: Decodable {
    case string(String)
    case blocks([PiSessionContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .blocks((try? container.decode([PiSessionContentBlock].self)) ?? [])
    }

    var plainText: String {
        switch self {
        case .string(let value):
            return value
        case .blocks(let blocks):
            return blocks.compactMap { block in
                block.type == "text" ? block.text : nil
            }.joined(separator: "")
        }
    }
}

private struct PiSessionContentBlock: Decodable {
    let type: String
    let text: String?
}

extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var terminalCardSummary: String {
        let collapsed = replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 180 else { return collapsed }
        return String(collapsed.prefix(179)) + "…"
    }
}
