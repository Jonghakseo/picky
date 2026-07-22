//
//  PickyTerminalOverlay.swift
//  Picky
//
//  In-app Pi terminal overlay backed by SwiftTerm.
//

import AppKit
import Combine
import CoreText
import Darwin
import Foundation
import SwiftTerm
import SwiftUI

struct PickyTerminalOverlayHandle: Hashable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

@MainActor
protocol PickyTerminalOverlayPresenting: AnyObject {
    func openTerminal(
        sessionID: String,
        title: String,
        sessionFilePath: String,
        cwd: String?,
        onClose: @escaping @MainActor (PickyTerminalOverlayHandle) -> Void
    ) throws -> PickyTerminalOverlayHandle
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

/// Window-scoped persistence hook so each open terminal panel can write its zoom
/// level back to the shared settings file the moment the user taps ⌘+ / ⌘-.
/// Mirrors `PickyMarkdownReportFontScalePersister` so the two overlays follow the
/// same pattern.
@MainActor
struct PickyTerminalFontScalePersister {
    let load: () -> Double
    let save: (Double) -> Void

    static func defaultSettings(settingsStore: PickySettingsStore = PickySettingsStore()) -> PickyTerminalFontScalePersister {
        PickyTerminalFontScalePersister(
            load: { settingsStore.load().fontScales.terminal },
            save: { newScale in
                var current = settingsStore.load()
                current.fontScales.terminal = PickyFontScales.clamped(newScale)
                try? settingsStore.save(current)
            }
        )
    }
}

/// Keeps terminal panels reopening independently from records that are only
/// retained while their child process flushes and exits.
@MainActor
final class PickyTerminalOverlayRecordStore<Record> {
    private struct ActiveRecord {
        let recordID: ObjectIdentifier
        let record: Record
    }

    private struct ClosingRecord {
        let sessionID: String
        let record: Record
    }

    private var activeRecordsBySessionID: [String: ActiveRecord] = [:]
    private var closingRecordsByID: [ObjectIdentifier: ClosingRecord] = [:]
    private var closingFinishedCallbacksBySessionID: [String: [() -> Void]] = [:]

    func activeRecord(sessionID: String) -> Record? {
        activeRecordsBySessionID[sessionID]?.record
    }

    func insert(_ record: Record, sessionID: String, recordID: ObjectIdentifier) {
        activeRecordsBySessionID[sessionID] = ActiveRecord(recordID: recordID, record: record)
    }

    @discardableResult
    func beginClosing(sessionID: String, recordID: ObjectIdentifier) -> Bool {
        guard let activeRecord = activeRecordsBySessionID[sessionID],
              activeRecord.recordID == recordID else {
            return false
        }
        activeRecordsBySessionID[sessionID] = nil
        closingRecordsByID[recordID] = ClosingRecord(sessionID: sessionID, record: activeRecord.record)
        return true
    }

    func finishClosing(recordID: ObjectIdentifier) {
        guard let closingRecord = closingRecordsByID.removeValue(forKey: recordID) else { return }
        guard !isClosing(sessionID: closingRecord.sessionID) else { return }
        let callbacks = closingFinishedCallbacksBySessionID.removeValue(forKey: closingRecord.sessionID) ?? []
        callbacks.forEach { $0() }
    }

    func isClosing(recordID: ObjectIdentifier) -> Bool {
        closingRecordsByID[recordID] != nil
    }

    func isClosing(sessionID: String) -> Bool {
        closingRecordsByID.values.contains { $0.sessionID == sessionID }
    }

    func onceClosingFinished(sessionID: String, _ callback: @escaping () -> Void) {
        guard isClosing(sessionID: sessionID) else {
            callback()
            return
        }
        closingFinishedCallbacksBySessionID[sessionID, default: []].append(callback)
    }
}

@MainActor
final class PickyTerminalOverlayPresenter: PickyTerminalOverlayPresenting {
    static let shared = PickyTerminalOverlayPresenter()

    private struct TerminalRecord {
        let handle: PickyTerminalOverlayHandle
        let panel: NSPanel
        let model: PickyTerminalModel
        let delegate: PickyTerminalPanelDelegate
        // Held strongly so the underlying NotificationCenter observers stay
        // alive for the panel's lifetime. See PickyDetachedPanelFrameAutosaver.
        let frameAutosaver: PickyDetachedPanelFrameAutosaver
    }

    private let recordStore = PickyTerminalOverlayRecordStore<TerminalRecord>()
    /// Held by the presenter for the lifetime of the app once `configure(appearanceStore:)`
    /// runs from `CompanionAppDelegate`. The fallback default keeps unit tests and
    /// previews working without crashing if `configure` was never called.
    private var appearanceStore = PickyAppearanceStore()
    private var fontScaleStore = PickyAppFontScaleStore()
    /// Shared settings store used to load/persist the terminal zoom level.
    /// Falls back to the default settings location for tests and previews.
    private var settingsStore = PickySettingsStore()

    private init() {}

    /// Wires the live appearance store so the terminal panel flips with the rest of
    /// the app. Called once from `CompanionAppDelegate` at startup.
    func configure(
        appearanceStore: PickyAppearanceStore,
        fontScaleStore: PickyAppFontScaleStore,
        settingsStore: PickySettingsStore = PickySettingsStore()
    ) {
        self.appearanceStore = appearanceStore
        self.fontScaleStore = fontScaleStore
        self.settingsStore = settingsStore
    }

    func openTerminal(
        sessionID: String,
        title: String,
        sessionFilePath: String,
        cwd: String?,
        onClose: @escaping @MainActor (PickyTerminalOverlayHandle) -> Void
    ) throws -> PickyTerminalOverlayHandle {
        if let existing = recordStore.activeRecord(sessionID: sessionID) {
            NSApp.activate(ignoringOtherApps: true)
            existing.panel.orderFrontRegardless()
            existing.panel.makeKey()
            return existing.handle
        }

        let processStartGate = PickyTerminalProcessStartGate()
        if recordStore.isClosing(sessionID: sessionID) {
            processStartGate.hold()
            recordStore.onceClosingFinished(sessionID: sessionID) {
                processStartGate.open()
            }
        }
        let model = PickyTerminalModel(
            title: title,
            sessionFilePath: sessionFilePath,
            cwd: cwd,
            fontScalePersister: makeFontScalePersister(),
            processStartGate: processStartGate
        )
        try model.prepare()

        let panel = PickyTerminalPanel(
            contentRect: targetFrame(),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pi Terminal — \(title)"
        panel.level = .normal
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = PickyAppearancePanelChrome.windowBackground()
        panel.minSize = NSSize(width: 680, height: 420)
        // Persist the last user-moved frame through PickySettingsStore so the
        // terminal overlay reopens where the user last left it; see
        // PickyDetachedPanelFrameAutosaver for why we no longer rely on
        // NSWindow.setFrameAutosaveName here.
        let frameAutosaver = PickyDetachedPanelFrameAutosaver(
            panel: panel,
            persister: PickyDetachedPanelFramePersister.backed(by: settingsStore, kind: .terminalOverlay)
        )

        let rootView = PickyAppFontScaleRoot(store: fontScaleStore) {
            PickyTerminalOverlayView(model: model)
                .environmentObject(self.appearanceStore)
                .modifier(PickyPreferredColorSchemeModifier(store: self.appearanceStore))
        }
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { rootView })
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        // Defer the post-overlay sync until pi's child process actually exits so the
        // session jsonl is fully flushed before the daemon reads it. Closing moves the
        // record out of the active lookup immediately, while a separate closing bucket
        // keeps the model alive long enough for SwiftTerm to deliver `processTerminated`.
        let handle = PickyTerminalOverlayHandle()
        let panelID = ObjectIdentifier(panel)
        let delegate = PickyTerminalPanelDelegate { [weak self, weak model] in
            self?.recordStore.beginClosing(sessionID: sessionID, recordID: panelID)
            let cleanup: @MainActor () -> Void = {
                onClose(handle)
            }
            guard let model else {
                self?.recordStore.finishClosing(recordID: panelID)
                cleanup()
                return
            }
            model.scheduleAfterActualProcessExit { [weak self] in
                self?.recordStore.finishClosing(recordID: panelID)
            }
            model.scheduleSyncOnExit(cleanup)
            model.close()
        }
        panel.delegate = delegate
        let record = TerminalRecord(handle: handle, panel: panel, model: model, delegate: delegate, frameAutosaver: frameAutosaver)
        recordStore.insert(record, sessionID: sessionID, recordID: panelID)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        return handle
    }

    private func makeFontScalePersister() -> PickyTerminalFontScalePersister {
        let store = settingsStore
        return PickyTerminalFontScalePersister(
            load: { store.load().fontScales.terminal },
            save: { newScale in
                var current = store.load()
                current.fontScales.terminal = PickyFontScales.clamped(newScale)
                try? store.save(current)
            }
        )
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePickyCloseWindowShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if handlePickyCloseWindowShortcut(event) { return }
        if event.type == .keyDown,
           let terminal = focusedTerminalView,
           terminal.handleMacLineEditingShortcut(event) {
            return
        }
        super.sendEvent(event)
    }

    private var focusedTerminalView: PickySwiftTermView? {
        var currentView = firstResponder as? NSView
        while let view = currentView {
            if let terminal = view as? PickySwiftTermView { return terminal }
            currentView = view.superview
        }
        return nil
    }
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

/// Defers the "sync the session card" callback until the pi child process has
/// finished writing its session jsonl. Pulled out of `PickyTerminalModel` so the
/// flush-race fix can be unit-tested without depending on SwiftTerm.
@MainActor
final class PickyTerminalExitSyncScheduler {
    /// Default wait before falling back to firing the sync anyway. Tests pass a
    /// shorter interval to keep timing-sensitive cases fast.
    nonisolated static let defaultFallbackInterval: TimeInterval = 2.0

    private(set) var hasStarted = false
    private(set) var hasExited = false
    private var pendingBlock: (@MainActor () -> Void)?
    private var fallbackTask: Task<Void, Never>?
    let fallbackInterval: TimeInterval

    init(fallbackInterval: TimeInterval = PickyTerminalExitSyncScheduler.defaultFallbackInterval) {
        self.fallbackInterval = fallbackInterval
    }

    func markStarted() {
        hasStarted = true
    }

    func markExited() {
        hasExited = true
        firePending()
    }

    func scheduleOnExit(_ block: @escaping @MainActor () -> Void) {
        if !hasStarted || hasExited {
            block()
            return
        }
        pendingBlock = block
        fallbackTask?.cancel()
        let interval = fallbackInterval
        fallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            self?.firePending()
        }
    }

    var hasPendingSync: Bool { pendingBlock != nil }

    private func firePending() {
        fallbackTask?.cancel()
        fallbackTask = nil
        guard let block = pendingBlock else { return }
        pendingBlock = nil
        block()
    }
}

@MainActor
protocol PickyTerminalProcessHosting: AnyObject {
    var processDelegate: LocalProcessTerminalViewDelegate? { get set }
    var processID: pid_t { get }

    func startPickyProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        currentDirectory: String?
    )
}

extension LocalProcessTerminalView: PickyTerminalProcessHosting {
    var processID: pid_t { process.shellPid }

    func startPickyProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        currentDirectory: String?
    ) {
        startProcess(
            executable: executable,
            args: args,
            environment: environment,
            currentDirectory: currentDirectory
        )
    }
}

@MainActor
final class PickyTerminalProcessTerminator {
    private let forceKillDelayNanoseconds: UInt64
    private let signalProcess: (pid_t, Int32) -> Void
    private var forceKillTask: Task<Void, Never>?

    init(
        forceKillDelayNanoseconds: UInt64 = 2_000_000_000,
        signalProcess: @escaping (pid_t, Int32) -> Void = { processID, signal in
            _ = Darwin.kill(processID, signal)
        }
    ) {
        self.forceKillDelayNanoseconds = forceKillDelayNanoseconds
        self.signalProcess = signalProcess
    }

    func terminate(processID: pid_t) {
        guard processID > 0 else { return }
        forceKillTask?.cancel()
        signalProcess(processID, SIGTERM)
        forceKillTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.forceKillDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self.signalProcess(processID, SIGKILL)
        }
    }

    func processExited() {
        forceKillTask?.cancel()
        forceKillTask = nil
    }
}

@MainActor
final class PickyTerminalProcessStartGate {
    private(set) var isOpen = true
    private var pendingStart: (@MainActor () -> Void)?

    func hold() {
        isOpen = false
    }

    func runWhenOpen(_ block: @escaping @MainActor () -> Void) {
        guard !isOpen else {
            block()
            return
        }
        pendingStart = block
    }

    func open() {
        isOpen = true
        let block = pendingStart
        pendingStart = nil
        block?()
    }

    func cancelPendingStart() {
        pendingStart = nil
    }
}

@MainActor
protocol PickyTerminalProcessEventHandling: AnyObject {
    func updateTerminalTitle(_ terminalTitle: String)
    func processExited(exitCode: Int32?)
}

/// SwiftTerm keeps this delegate weakly. The terminal model owns this adapter
/// so process-exit delivery survives SwiftUI representable replacement.
final class PickyTerminalProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    private weak var handler: (any PickyTerminalProcessEventHandling)?

    @MainActor
    init(handler: any PickyTerminalProcessEventHandling) {
        self.handler = handler
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.handler?.updateTerminalTitle(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.handler?.processExited(exitCode: exitCode)
        }
    }
}

@MainActor
final class PickyTerminalModel: ObservableObject, PickyTerminalProcessEventHandling {
    @Published private(set) var statusText = "Starting pi --session…"
    /// Live zoom multiplier for the SwiftTerm grid font. Bound to
    /// `PickyFontScales.minimum/maximum` and rounded to one decimal so ⌘+ taps
    /// don't drift. Persisted via `fontScalePersister` whenever the user changes it.
    @Published private(set) var fontScale: Double

    let title: String
    let sessionFilePath: String
    let cwd: String?

    private weak var terminalView: (any PickyTerminalProcessHosting)?
    /// SwiftTerm cancels its process monitor inside `terminate()`. Keep the view
    /// alive and signal its PID directly so `processTerminated` can still arrive.
    private var closingTerminalView: (any PickyTerminalProcessHosting)?
    private var didStartProcess = false
    private var actualProcessExitCallbacks: [@MainActor () -> Void] = []
    private(set) lazy var processDelegate = PickyTerminalProcessDelegate(handler: self)
    private let exitSync: PickyTerminalExitSyncScheduler
    private let processStartGate: PickyTerminalProcessStartGate
    private let processTerminator: PickyTerminalProcessTerminator
    private let fontScalePersister: PickyTerminalFontScalePersister?

    init(
        title: String,
        sessionFilePath: String,
        cwd: String?,
        fontScalePersister: PickyTerminalFontScalePersister? = nil,
        exitSync: PickyTerminalExitSyncScheduler? = nil,
        processStartGate: PickyTerminalProcessStartGate? = nil,
        processTerminator: PickyTerminalProcessTerminator? = nil
    ) {
        self.title = title
        self.sessionFilePath = sessionFilePath
        self.cwd = cwd
        self.fontScalePersister = fontScalePersister
        self.exitSync = exitSync ?? PickyTerminalExitSyncScheduler()
        self.processStartGate = processStartGate ?? PickyTerminalProcessStartGate()
        self.processTerminator = processTerminator ?? PickyTerminalProcessTerminator()
        self.fontScale = PickyFontScales.clamped(fontScalePersister?.load() ?? PickyFontScales.defaults.terminal)
    }

    func zoomIn() { setFontScale(fontScale + PickyFontScales.step) }
    func zoomOut() { setFontScale(fontScale - PickyFontScales.step) }
    func resetZoom() { setFontScale(PickyFontScales.defaults.terminal) }

    private func setFontScale(_ newValue: Double) {
        let clamped = PickyFontScales.clamped(newValue)
        guard clamped != fontScale else { return }
        fontScale = clamped
        fontScalePersister?.save(clamped)
    }

    func prepare() throws {
        guard FileManager.default.fileExists(atPath: sessionFilePath) else {
            throw PickyTerminalOverlayError.failedToStart("Session file does not exist: \(sessionFilePath)")
        }
        statusText = "Attached to \(compactPath(sessionFilePath))"
    }

    func attach(_ terminalView: LocalProcessTerminalView) {
        attachProcessHostForTesting(terminalView)
    }

    func attachProcessHostForTesting(_ terminalView: any PickyTerminalProcessHosting) {
        terminalView.processDelegate = processDelegate
        self.terminalView = terminalView
        startProcessIfNeeded(in: terminalView)
    }

    func close() {
        processStartGate.cancelPendingStart()
        guard didStartProcess, let terminalView else {
            self.terminalView = nil
            didStartProcess = false
            return
        }
        closingTerminalView = terminalView
        self.terminalView = nil
        processTerminator.terminate(processID: terminalView.processID)
    }

    func processExited(exitCode: Int32?) {
        processTerminator.processExited()
        terminalView = nil
        closingTerminalView = nil
        didStartProcess = false
        if let exitCode {
            statusText = "Pi terminal exited with code \(exitCode). Close to sync the session card."
        } else {
            statusText = "Pi terminal closed. Close to sync the session card."
        }
        let callbacks = actualProcessExitCallbacks
        actualProcessExitCallbacks.removeAll()
        callbacks.forEach { $0() }
        exitSync.markExited()
    }

    func scheduleAfterActualProcessExit(_ block: @escaping @MainActor () -> Void) {
        guard didStartProcess else {
            block()
            return
        }
        actualProcessExitCallbacks.append(block)
    }

    /// Defers the post-overlay sync until pi reports `processTerminated` so the
    /// session jsonl is fully flushed before the daemon reads it.
    func scheduleSyncOnExit(_ block: @escaping @MainActor () -> Void) {
        exitSync.scheduleOnExit(block)
    }

    func updateTerminalTitle(_ terminalTitle: String) {
        guard !terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        statusText = "Attached to \(compactPath(sessionFilePath))"
    }

    private func startProcessIfNeeded(in terminalView: any PickyTerminalProcessHosting) {
        guard !didStartProcess else { return }
        if !processStartGate.isOpen {
            statusText = "Waiting for the previous Pi terminal to close…"
        }
        processStartGate.runWhenOpen { [weak self, weak terminalView] in
            guard let self, let terminalView, self.terminalView === terminalView, !self.didStartProcess else { return }
            self.didStartProcess = true
            self.statusText = "Attached to \(self.compactPath(self.sessionFilePath))"
            self.exitSync.markStarted()
            let command = PickyPiTerminalCommand.makeOverlayCommand(sessionFilePath: self.sessionFilePath, cwd: self.cwd)
            terminalView.startPickyProcess(
                executable: "/bin/zsh",
                args: ["-lc", command],
                environment: PickyPiTerminalCommand.makeOverlayEnvironment(),
                currentDirectory: PickyPiTerminalCommand.workingDirectory(from: self.cwd)
            )
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
                    .foregroundColor(DS.Colors.successText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(model.statusText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("⌘W / close syncs once")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            PickySwiftTermViewRepresentable(model: model)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(PickyAppearancePanelChrome.overlayBackground)
        .background(zoomKeyboardShortcuts)
    }

    /// Hidden buttons that bind ⌘+ / ⌘- / ⌘0 to the model's zoom controls.
    /// Placed in a `.background(...)` of zero size so they exist in the responder chain
    /// without taking layout space or showing focus rings.
    private var zoomKeyboardShortcuts: some View {
        ZStack {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Zoom") { model.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

struct PickySwiftTermViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: PickyTerminalModel

    func makeNSView(context: Context) -> PickySwiftTermView {
        let terminalView = PickySwiftTermView(frame: .zero)
        terminalView.processDelegate = model.processDelegate
        terminalView.autoresizingMask = [.width, .height]
        terminalView.configurePickyAppearance(fontScale: model.fontScale)
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        model.attach(terminalView)
        return terminalView
    }

    func updateNSView(_ terminalView: PickySwiftTermView, context: Context) {
        terminalView.processDelegate = model.processDelegate
        // Re-applies font sizing whenever the model's `fontScale` changes (⌘+ / ⌘- / ⌘0).
        // `applyFontScale` is idempotent for unchanged scales so SwiftUI updates do not
        // trigger SwiftTerm font resets/resizes.
        terminalView.applyFontScale(model.fontScale)
        if terminalView.window?.firstResponder == nil {
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }
    }
}

enum PickyTerminalFontResolver {
    static let environmentFontKey = "PICKY_TERMINAL_FONT"
    static let bundledSymbolsFontResourceName = "SymbolsNerdFontMono-Regular"
    static let bundledSymbolsFontNames = [
        "Symbols Nerd Font Mono",
        "SymbolsNFM",
        "SymbolsNerdFontMono-Regular",
    ]
    static let terminalFallbackFontNames = [
        "Apple Color Emoji",
        "Symbols Nerd Font Mono",
        "SymbolsNFM",
        "SymbolsNerdFontMono-Regular",
        "Apple Symbols",
        "D2Coding",
    ]
    private static var registeredBundledFontURLs = Set<URL>()

    static func font(
        ofSize size: CGFloat,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        ghosttyConfigContents: String? = defaultGhosttyConfigContents(),
        fontProvider: (String, CGFloat) -> NSFont? = { NSFont(name: $0, size: $1) }
    ) -> NSFont {
        registerBundledTerminalFonts()
        let selected = selectedFontName(
            environment: environment,
            ghosttyConfigContents: ghosttyConfigContents,
            isFontAvailable: { fontProvider($0, size) != nil }
        )
        let base = selected.flatMap { fontProvider($0, size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return addingTerminalFallbacks(to: base, size: size, fontProvider: fontProvider)
    }

    static func selectedFontName(
        environment: [String: String],
        ghosttyConfigContents: String?,
        isFontAvailable: (String) -> Bool
    ) -> String? {
        candidateFontNames(environment: environment, ghosttyConfigContents: ghosttyConfigContents)
            .first(where: isFontAvailable)
    }

    static func candidateFontNames(environment: [String: String], ghosttyConfigContents: String?) -> [String] {
        var candidates: [String] = []
        appendFontFamilies(from: environment[environmentFontKey], to: &candidates)
        candidates.append(contentsOf: ghosttyFontFamilies(from: ghosttyConfigContents ?? ""))
        candidates.append(contentsOf: [
            "MesloLGS Nerd Font Mono",
            "MesloLGS NF",
            "JetBrainsMono Nerd Font Mono",
            "JetBrainsMono Nerd Font",
            "Hack Nerd Font Mono",
            "FiraCode Nerd Font Mono",
            "D2Coding",
        ])
        return deduplicated(candidates)
    }

    static func ghosttyFontFamilies(from config: String) -> [String] {
        config.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let uncommented = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let line = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("font-family") else { return nil }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return normalizedFontFamily(String(parts[1]))
        }
    }

    private static func appendFontFamilies(from value: String?, to candidates: inout [String]) {
        guard let value else { return }
        for rawName in value.split(separator: ",", omittingEmptySubsequences: true) {
            if let name = normalizedFontFamily(String(rawName)) {
                candidates.append(name)
            }
        }
    }

    private static func normalizedFontFamily(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func deduplicated(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }

    private static func defaultGhosttyConfigContents() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.config/ghostty/config"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    @discardableResult
    static func registerBundledTerminalFonts(bundle: Bundle = .main) -> Bool {
        guard let fontURL = bundledSymbolsFontURL(in: bundle) else { return false }
        guard !registeredBundledFontURLs.contains(fontURL) else { return true }
        var registrationError: Unmanaged<CFError>?
        let didRegister = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registrationError)
        registrationError?.release()
        registeredBundledFontURLs.insert(fontURL)
        return didRegister || NSFont(name: bundledSymbolsFontNames[0], size: 12) != nil
    }

    static func bundledSymbolsFontURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: bundledSymbolsFontResourceName,
            withExtension: "ttf",
            subdirectory: "Resources/Fonts"
        ) ?? bundle.url(
            forResource: bundledSymbolsFontResourceName,
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) ?? bundle.url(
            forResource: bundledSymbolsFontResourceName,
            withExtension: "ttf"
        )
    }

    private static func addingTerminalFallbacks(
        to base: NSFont,
        size: CGFloat,
        fontProvider: (String, CGFloat) -> NSFont?
    ) -> NSFont {
        let fallbackDescriptors = deduplicated([
            base.familyName ?? base.fontName,
        ] + terminalFallbackFontNames).compactMap { name -> NSFontDescriptor? in
            guard name != base.familyName && name != base.fontName else { return nil }
            return fontProvider(name, size)?.fontDescriptor
        }
        guard !fallbackDescriptors.isEmpty else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: fallbackDescriptors])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

final class PickySwiftTermView: LocalProcessTerminalView {
    /// Cell size at scale 1.0. Bumped from the original 11.5pt because users reported
    /// the in-app terminal felt cramped on Retina displays compared to Ghostty.
    static let baseFontSize: CGFloat = 13
    /// SwiftTerm defaults to 500 scrollback lines, which is too small for resumed Pi
    /// sessions with long transcripts. Keep the visual card size unchanged, but retain
    /// enough terminal history for users to scroll through the TUI output.
    static let scrollbackLineLimit = 20_000

    private var appliedFontScale: Double?

    func configurePickyAppearance(fontScale: Double = 1.0) {
        applyFontScale(fontScale)
        applyAppearanceColors()
        applyScrollbackLineLimit()
        backspaceSendsControlH = false
        caretViewTracksFocus = false
        antiAliasCustomBlockGlyphs = false
        postsFrameChangedNotifications = true
        // SwiftTerm's macOS view has no NSDraggingDestination support, so file drops
        // (e.g. dragging an image into the Pickle TUI) were rejected at the AppKit
        // level before any text could reach the pty. Register here so every Picky
        // terminal surface (inline card, extended view, overlay) accepts them.
        registerForDraggedTypes([.fileURL])
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScrollbackLineLimit()
    }

    private func applyScrollbackLineLimit() {
        guard terminal != nil else { return }
        guard terminal.options.scrollback != Self.scrollbackLineLimit else { return }
        changeScrollback(Self.scrollbackLineLimit)
    }

    /// Re-renders the SwiftTerm grid at `Self.baseFontSize * fontScale` only when
    /// the scale actually changes. SwiftTerm's font setter resets and resizes the
    /// terminal, so repeated SwiftUI `updateNSView` calls must not reassign it for
    /// the same scale.
    func applyFontScale(_ scale: Double) {
        guard appliedFontScale != scale else { return }
        appliedFontScale = scale
        let size = Self.baseFontSize * CGFloat(scale)
        font = PickyTerminalFontResolver.font(ofSize: size)
    }

    /// Re-resolves SwiftTerm's native colors from `effectiveAppearance` so the
    /// terminal repaints into a light palette when the user flips the companion
    /// footer toggle. AppKit calls this whenever the host's `.preferredColorScheme`
    /// changes, so no explicit notification wiring is needed.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // SwiftTerm caches NSColor components at assignment time, so we resolve up front
        // instead of handing it a dynamic NSColor that would only flip on next reassignment.
        let foreground = isDark
            ? NSColor(calibratedWhite: 0.90, alpha: 1)
            : NSColor(calibratedWhite: 0.10, alpha: 1)
        let background = PickyAppearancePanelChrome.resolvedOverlayBackground(isDark: isDark)
        nativeForegroundColor = foreground
        nativeBackgroundColor = background
        layer?.backgroundColor = background.cgColor
    }

    /// macOS turns the line-editing chords ⌘←, ⌘→, and ⌘⌫ into selectors that
    /// SwiftTerm either drops (`deleteToBeginningOfLine:` has no case) or maps to
    /// emacs word-motion escapes Pi's line editor does not interpret, so the keys
    /// look dead in the inline TUI. SwiftTerm declares `keyDown` as `public` (not
    /// `open`), so we cannot override it; instead the window/monitor chokepoints
    /// call this before the event reaches SwiftTerm. Always send the readline
    /// control bytes directly: SwiftTerm's native command-arrow/delete handling is
    /// inconsistent even after a TUI enables keyboard enhancement flags.
    @discardableResult
    func handleMacLineEditingShortcut(_ event: NSEvent) -> Bool {
        guard let bytes = Self.macLineEditingShortcutBytes(for: event) else { return false }
        send(bytes)
        return true
    }

    static func macLineEditingShortcutBytes(for event: NSEvent) -> [UInt8]? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command else { return nil }
        switch event.keyCode {
        case 51: return [0x15]   // ⌘⌫ -> Ctrl-U (delete to start of line)
        case 123: return [0x01]  // ⌘← -> Ctrl-A (move to start of line)
        case 124: return [0x05]  // ⌘→ -> Ctrl-E (move to end of line)
        default: return nil
        }
    }

    // MARK: - File drag & drop

    // Mirrors the Terminal.app/iTerm2/Ghostty convention: dropping files types their
    // shell-escaped paths into the terminal input, so Pi's TUI sees them exactly as
    // if the user had typed the paths.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !droppedFileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        let text = Self.droppedFilesInputText(for: urls.map(\.path))
        // Wrap in bracketed paste when the TUI enabled it, matching SwiftTerm's own
        // paste path, so Pi's line editor receives the paths as one literal chunk.
        if terminal.bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[0...])
            send(txt: text)
            send(data: EscapeSequences.bracketedPasteEnd[0...])
        } else {
            send(txt: text)
        }
        window?.makeFirstResponder(self)
        return true
    }

    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return urls ?? []
    }

    /// Space-separated shell-escaped paths with a trailing space so the user can
    /// keep typing (or drop more files) without inserting a separator manually.
    static func droppedFilesInputText(for paths: [String]) -> String {
        paths.map(shellEscapedPath).joined(separator: " ") + " "
    }

    /// Backslash-escapes shell metacharacters the way Terminal.app does for file
    /// drops. Alphanumerics (including non-ASCII letters) and common path chars
    /// pass through untouched so ordinary paths stay readable.
    static func shellEscapedPath(_ path: String) -> String {
        let safeScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@%,:=~"))
        guard path.unicodeScalars.contains(where: { !safeScalars.contains($0) }) else { return path }
        var escaped = ""
        escaped.reserveCapacity(path.count * 2)
        for character in path {
            if character.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
                escaped.append(character)
            } else {
                escaped.append("\\")
                escaped.append(character)
            }
        }
        return escaped
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
    var lastMessageId: String?

    var isEmpty: Bool {
        lastUserText == nil && lastAssistantText == nil && lastMessageId == nil
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
            .filter { $0.id != nil }

        let activePath = activeMessagePath(from: entries)
        let lastUserText = activePath.reversed().first { entry in
            entry.message?.role == "user" && entry.message?.plainText.nonEmptyTrimmed != nil
        }?.message?.plainText.nonEmptyTrimmed
        let lastAssistantText = activePath.reversed().first { entry in
            entry.message?.role == "assistant" && entry.message?.plainText.nonEmptyTrimmed != nil
        }?.message?.plainText.nonEmptyTrimmed
        let lastVisibleEntry = activePath.reversed().first { entry in
            guard let message = entry.message,
                  message.role == "user" || message.role == "assistant" else { return false }
            return message.plainText.nonEmptyTrimmed != nil
        }
        return PickyTerminalSessionSnapshot(lastUserText: lastUserText, lastAssistantText: lastAssistantText, lastMessageId: lastVisibleEntry?.id)
    }

    private func activeMessagePath(from entries: [PiSessionMessageEntry]) -> [PiSessionMessageEntry] {
        guard var current = entries.last(where: { entry in
            entry.message?.role == "user" || entry.message?.role == "assistant"
        }) else { return [] }
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
