//
//  PickyTerminalOverlay.swift
//  Picky
//
//  Lightweight in-app Pi terminal overlay for quickly resuming a saved Pi session.
//

import AppKit
import Combine
import Darwin
import Foundation
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
    private let columns = 100
    private let rows = 30

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
            cwd: cwd,
            columns: columns,
            rows: rows
        )
        try model.start()

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
        panel.minSize = NSSize(width: 560, height: 320)

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
        let width = min(CGFloat(860), visibleFrame.width - 48)
        let height = min(CGFloat(520), visibleFrame.height - 48)
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
    @Published private(set) var screenText: String
    @Published private(set) var statusText = "Starting pi --session…"

    let title: String
    let sessionFilePath: String
    let cwd: String?

    private var emulator: PickyTerminalEmulator
    private var process: PickyTerminalProcess?
    private let columns: Int
    private let rows: Int

    init(title: String, sessionFilePath: String, cwd: String?, columns: Int, rows: Int) {
        self.title = title
        self.sessionFilePath = sessionFilePath
        self.cwd = cwd
        self.columns = columns
        self.rows = rows
        self.emulator = PickyTerminalEmulator(columns: columns, rows: rows)
        self.screenText = emulator.renderedText()
    }

    func start() throws {
        let command = PickyPiTerminalCommand.makeOverlayCommand(sessionFilePath: sessionFilePath, cwd: cwd)
        do {
            process = try PickyTerminalProcess(
                command: command,
                cwd: PickyPiTerminalCommand.workingDirectory(from: cwd),
                columns: columns,
                rows: rows,
                onOutput: { [weak self] data in
                    Task { @MainActor in self?.receive(data) }
                },
                onExit: { [weak self] exitCode in
                    Task { @MainActor in self?.processExited(exitCode: exitCode) }
                }
            )
            statusText = "Attached to \(compactPath(sessionFilePath))"
        } catch {
            throw PickyTerminalOverlayError.failedToStart(error.localizedDescription)
        }
    }

    func send(_ data: Data) {
        process?.write(data)
    }

    func close() {
        process?.terminate()
        process = nil
    }

    private func receive(_ data: Data) {
        emulator.feed(data)
        screenText = emulator.renderedText()
    }

    private func processExited(exitCode: Int32?) {
        process = nil
        if let exitCode {
            statusText = "Pi terminal exited with code \(exitCode). Close to sync the session card."
        } else {
            statusText = "Pi terminal closed. Close to sync the session card."
        }
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

            PickyTerminalTextViewRepresentable(text: model.screenText) { data in
                model.send(data)
            }
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

struct PickyTerminalTextViewRepresentable: NSViewRepresentable {
    let text: String
    let onInput: (Data) -> Void

    func makeNSView(context: Context) -> PickyTerminalScrollView {
        let textView = PickyTerminalTextView()
        textView.inputHandler = onInput
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(calibratedRed: 0.02, green: 0.024, blue: 0.03, alpha: 1)
        textView.textColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        textView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text

        let scrollView = PickyTerminalScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.resizeTerminalDocumentView()

        DispatchQueue.main.async {
            scrollView.resizeTerminalDocumentView()
            scrollView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: PickyTerminalScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PickyTerminalTextView else { return }
        textView.inputHandler = onInput
        if textView.string != text {
            textView.string = text
            scrollView.resizeTerminalDocumentView()
            textView.scrollToEndOfDocument(nil)
        }
        DispatchQueue.main.async {
            scrollView.resizeTerminalDocumentView()
            if scrollView.window?.firstResponder == nil {
                scrollView.window?.makeFirstResponder(textView)
            }
        }
    }
}

final class PickyTerminalScrollView: NSScrollView {
    override func layout() {
        super.layout()
        resizeTerminalDocumentView()
    }

    func resizeTerminalDocumentView() {
        guard let textView = documentView as? NSTextView else { return }
        let contentSize = contentSize
        let width = max(1, contentSize.width)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = width

        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2)
            textView.frame.size.height = max(contentSize.height, usedHeight)
        } else {
            textView.frame.size.height = max(contentSize.height, textView.frame.height)
        }
    }
}

final class PickyTerminalTextView: NSTextView {
    var inputHandler: ((Data) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            super.keyDown(with: event)
            return
        }
        guard let data = PickyTerminalKeyMapper.data(for: event) else {
            super.keyDown(with: event)
            return
        }
        inputHandler?(data)
    }
}

enum PickyTerminalKeyMapper {
    static func data(for event: NSEvent) -> Data? {
        switch event.keyCode {
        case 36, 76:
            return Data([13])
        case 48:
            return Data([9])
        case 51, 117:
            return Data([127])
        case 53:
            return Data([27])
        case 123:
            return Data("\u{1B}[D".utf8)
        case 124:
            return Data("\u{1B}[C".utf8)
        case 125:
            return Data("\u{1B}[B".utf8)
        case 126:
            return Data("\u{1B}[A".utf8)
        default:
            break
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control),
           let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
           scalar.value >= 64,
           scalar.value <= 126 {
            return Data([UInt8(scalar.value & 0x1F)])
        }

        guard let characters = event.characters, !characters.isEmpty else { return nil }
        return characters.data(using: .utf8)
    }
}

final class PickyTerminalProcess {
    private let queue = DispatchQueue(label: "com.jonghakseo.picky.terminal-process")
    private let onOutput: (Data) -> Void
    private let onExit: (Int32?) -> Void
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private var didFinish = false

    init(
        command: String,
        cwd: String,
        columns: Int,
        rows: Int,
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32?) -> Void
    ) throws {
        self.onOutput = onOutput
        self.onExit = onExit
        try start(command: command, cwd: cwd, columns: columns, rows: rows)
    }

    deinit {
        if !didFinish, childPID > 0 {
            Darwin.kill(childPID, SIGHUP)
            Darwin.kill(childPID, SIGTERM)
        }
        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }
    }

    func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0, !self.didFinish else { return }
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                _ = Darwin.write(self.masterFD, baseAddress, rawBuffer.count)
            }
        }
    }

    func terminate() {
        queue.async {
            guard !self.didFinish else { return }
            if self.childPID > 0 {
                Darwin.kill(self.childPID, SIGHUP)
                Darwin.kill(self.childPID, SIGTERM)
            }
            self.finish(exitCode: nil)
        }
    }

    private func start(command: String, cwd: String, columns: Int, rows: Int) throws {
        var master: Int32 = -1
        var size = winsize(ws_row: UInt16(max(10, rows)), ws_col: UInt16(max(40, columns)), ws_xpixel: 0, ws_ypixel: 0)
        let executable = "/bin/zsh"
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(executable),
            strdup("-lc"),
            strdup(command),
            nil,
        ]
        defer {
            for arg in argv {
                if let arg { free(arg) }
            }
        }

        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 {
            throw POSIXError.fromErrno()
        }

        if pid == 0 {
            setTerminalEnvironment(columns: columns, rows: rows)
            cwd.withCString { pointer in
                _ = Darwin.chdir(pointer)
            }
            execv(executable, &argv)
            _exit(127)
        }

        masterFD = master
        childPID = pid
        configureReadSource(fileDescriptor: master)
        configureProcessSource(pid: pid)
    }

    private func setTerminalEnvironment(columns: Int, rows: Int) {
        setenv("TERM", "xterm-256color", 1)
        setenv("COLORTERM", "truecolor", 1)
        setenv("TERM_PROGRAM", "Picky", 1)
        setenv("COLUMNS", String(max(40, columns)), 1)
        setenv("LINES", String(max(10, rows)), 1)
        if getenv("LANG") == nil {
            setenv("LANG", "en_US.UTF-8", 1)
        }
        if getenv("LC_CTYPE") == nil {
            setenv("LC_CTYPE", "en_US.UTF-8", 1)
        }
    }

    private func configureReadSource(fileDescriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                self.onOutput(Data(buffer.prefix(count)))
            } else if count == 0 || errno != EAGAIN {
                self.finish(exitCode: nil)
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.masterFD >= 0 {
                Darwin.close(self.masterFD)
                self.masterFD = -1
            }
        }
        readSource = source
        source.resume()
    }

    private func configureProcessSource(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            self.finish(exitCode: Self.exitCode(fromWaitStatus: status))
        }
        processSource = source
        source.resume()
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32? {
        let signalStatus = status & 0x7F
        if signalStatus == 0 {
            return (status >> 8) & 0xFF
        }
        if signalStatus != 0x7F {
            return 128 + signalStatus
        }
        return nil
    }

    private func finish(exitCode: Int32?) {
        guard !didFinish else { return }
        didFinish = true
        var resolvedExitCode = exitCode
        if resolvedExitCode == nil, childPID > 0 {
            var status: Int32 = 0
            if waitpid(childPID, &status, WNOHANG) == childPID {
                resolvedExitCode = Self.exitCode(fromWaitStatus: status)
            }
        }
        readSource?.cancel()
        readSource = nil
        processSource?.cancel()
        processSource = nil
        onExit(resolvedExitCode)
    }
}

private extension POSIXError {
    static func fromErrno() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct PickyTerminalEmulator {
    private enum ParserState: Equatable {
        case normal
        case escape
        case csi(String)
        case osc
        case oscEscape
    }

    private let columns: Int
    private let rows: Int
    private var grid: [[Character]]
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursor: (row: Int, column: Int)?
    private var state: ParserState = .normal

    init(columns: Int, rows: Int) {
        self.columns = max(40, columns)
        self.rows = max(10, rows)
        self.grid = Array(repeating: Array(repeating: " ", count: max(40, columns)), count: max(10, rows))
    }

    mutating func feed(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        for scalar in text.unicodeScalars {
            process(scalar)
        }
    }

    func renderedText() -> String {
        grid.map { row in
            String(row).trimmingTrailingSpaces()
        }
        .joined(separator: "\n")
    }

    private mutating func process(_ scalar: UnicodeScalar) {
        switch state {
        case .normal:
            processNormal(scalar)
        case .escape:
            processEscape(scalar)
        case .csi(let sequence):
            processCSI(sequence: sequence, scalar: scalar)
        case .osc:
            processOSC(scalar)
        case .oscEscape:
            processOSCEscape(scalar)
        }
    }

    private mutating func processNormal(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x1B:
            state = .escape
        case 0x0D:
            cursorColumn = 0
        case 0x0A:
            newline()
        case 0x08:
            cursorColumn = max(0, cursorColumn - 1)
        case 0x09:
            let nextTab = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
            while cursorColumn < nextTab { put(" ") }
        default:
            guard !CharacterSet.controlCharacters.contains(scalar) else { return }
            if isUnsupportedTerminalGlyph(scalar) {
                put(" ")
            } else {
                put(Character(scalar))
            }
        }
    }

    private mutating func processEscape(_ scalar: UnicodeScalar) {
        switch scalar {
        case "[":
            state = .csi("")
        case "]":
            state = .osc
        case "c":
            clearAll()
            state = .normal
        case "7":
            savedCursor = (cursorRow, cursorColumn)
            state = .normal
        case "8":
            if let savedCursor {
                cursorRow = savedCursor.row
                cursorColumn = savedCursor.column
            }
            state = .normal
        default:
            state = .normal
        }
    }

    private mutating func processOSC(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x07:
            state = .normal
        case 0x1B:
            state = .oscEscape
        default:
            break
        }
    }

    private mutating func processOSCEscape(_ scalar: UnicodeScalar) {
        if scalar == "\\" {
            state = .normal
        } else if scalar.value == 0x07 {
            state = .normal
        } else {
            state = .osc
        }
    }

    private mutating func processCSI(sequence: String, scalar: UnicodeScalar) {
        guard scalar.value >= 0x40, scalar.value <= 0x7E else {
            state = .csi(sequence + String(scalar))
            return
        }
        handleCSI(sequence: sequence, final: Character(scalar))
        state = .normal
    }

    private mutating func handleCSI(sequence: String, final: Character) {
        let isPrivate = sequence.hasPrefix("?")
        let cleaned = sequence.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
        let params = cleaned
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let first = params.first ?? 0

        switch final {
        case "A":
            cursorRow = max(0, cursorRow - max(1, first))
        case "B":
            cursorRow = min(rows - 1, cursorRow + max(1, first))
        case "C":
            cursorColumn = min(columns - 1, cursorColumn + max(1, first))
        case "D":
            cursorColumn = max(0, cursorColumn - max(1, first))
        case "G":
            cursorColumn = clampedColumn(max(1, first) - 1)
        case "H", "f":
            let row = max(1, params[safe: 0] ?? 1) - 1
            let column = max(1, params[safe: 1] ?? 1) - 1
            cursorRow = clampedRow(row)
            cursorColumn = clampedColumn(column)
        case "J":
            handleEraseDisplay(first)
        case "K":
            handleEraseLine(first)
        case "s":
            savedCursor = (cursorRow, cursorColumn)
        case "u":
            if let savedCursor {
                cursorRow = savedCursor.row
                cursorColumn = savedCursor.column
            }
        case "h" where isPrivate && cleaned.contains("1049"):
            clearAll()
        case "l" where isPrivate && cleaned.contains("1049"):
            clearAll()
        default:
            break
        }
    }

    private func isUnsupportedTerminalGlyph(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0xE000...0xF8FF,
             0xF0000...0xFFFFD,
             0x100000...0x10FFFD,
             0xFFFD:
            return true
        default:
            return false
        }
    }

    private mutating func put(_ character: Character) {
        guard cursorRow >= 0, cursorRow < rows, cursorColumn >= 0, cursorColumn < columns else { return }
        grid[cursorRow][cursorColumn] = character
        cursorColumn += 1
        if cursorColumn >= columns {
            cursorColumn = 0
            newline()
        }
    }

    private mutating func newline() {
        if cursorRow >= rows - 1 {
            grid.removeFirst()
            grid.append(Array(repeating: " ", count: columns))
        } else {
            cursorRow += 1
        }
    }

    private mutating func clearAll() {
        grid = Array(repeating: Array(repeating: " ", count: columns), count: rows)
        cursorRow = 0
        cursorColumn = 0
    }

    private mutating func handleEraseDisplay(_ mode: Int) {
        switch mode {
        case 2, 3:
            clearAll()
        case 1:
            for row in 0...cursorRow {
                let endColumn = row == cursorRow ? cursorColumn : columns - 1
                guard endColumn >= 0 else { continue }
                for column in 0...endColumn { grid[row][column] = " " }
            }
        default:
            for row in cursorRow..<rows {
                let startColumn = row == cursorRow ? cursorColumn : 0
                guard startColumn < columns else { continue }
                for column in startColumn..<columns { grid[row][column] = " " }
            }
        }
    }

    private mutating func handleEraseLine(_ mode: Int) {
        switch mode {
        case 1:
            for column in 0...cursorColumn { grid[cursorRow][column] = " " }
        case 2:
            grid[cursorRow] = Array(repeating: " ", count: columns)
        default:
            guard cursorColumn < columns else { return }
            for column in cursorColumn..<columns { grid[cursorRow][column] = " " }
        }
    }

    private func clampedRow(_ row: Int) -> Int {
        min(max(0, row), rows - 1)
    }

    private func clampedColumn(_ column: Int) -> Int {
        min(max(0, column), columns - 1)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var result = self
        while result.last == " " {
            result.removeLast()
        }
        return result
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
