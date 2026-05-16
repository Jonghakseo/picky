//
//  PickyTerminalOverlay.swift
//  Picky
//
//  In-app Pi terminal overlay backed by SwiftTerm.
//

import AppKit
import Combine
import CoreText
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

@MainActor
final class PickyTerminalOverlayPresenter: PickyTerminalOverlayPresenting {
    static let shared = PickyTerminalOverlayPresenter()

    private struct TerminalRecord {
        let panel: NSPanel
        let model: PickyTerminalModel
        let delegate: PickyTerminalPanelDelegate
        // Held strongly so the underlying NotificationCenter observers stay
        // alive for the panel's lifetime. See PickyDetachedPanelFrameAutosaver.
        let frameAutosaver: PickyDetachedPanelFrameAutosaver
    }

    private var records: [String: TerminalRecord] = [:]
    /// Held by the presenter for the lifetime of the app once `configure(appearanceStore:)`
    /// runs from `CompanionAppDelegate`. The fallback default keeps unit tests and
    /// previews working without crashing if `configure` was never called.
    private var appearanceStore = PickyAppearanceStore()
    /// Shared settings store used to load/persist the terminal zoom level.
    /// Falls back to the default settings location for tests and previews.
    private var settingsStore = PickySettingsStore()

    private init() {}

    /// Wires the live appearance store so the terminal panel flips with the rest of
    /// the app. Called once from `CompanionAppDelegate` at startup.
    func configure(appearanceStore: PickyAppearanceStore, settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.appearanceStore = appearanceStore
        self.settingsStore = settingsStore
    }

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
            fontScalePersister: makeFontScalePersister()
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

        let rootView = PickyTerminalOverlayView(model: model)
            .environmentObject(appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { rootView })
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        // Defer the post-overlay sync until pi's child process actually exits so the
        // session jsonl is fully flushed before the daemon reads it. The model has to
        // outlive the panel close so SwiftTerm can still deliver `processTerminated`,
        // so we drop the panel record on the next runloop tick rather than inline.
        let delegate = PickyTerminalPanelDelegate { [weak self, weak model, weak panel] in
            let cleanup: @MainActor () -> Void = { [weak self, weak panel] in
                onClose()
                DispatchQueue.main.async {
                    if let panel { self?.remove(panel: panel) }
                }
            }
            guard let model else {
                cleanup()
                return
            }
            model.scheduleSyncOnExit(cleanup)
            model.close()
        }
        panel.delegate = delegate
        records[sessionID] = TerminalRecord(panel: panel, model: model, delegate: delegate, frameAutosaver: frameAutosaver)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func remove(panel: NSPanel) {
        records = records.filter { $0.value.panel !== panel }
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
        super.sendEvent(event)
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
final class PickyTerminalModel: ObservableObject {
    @Published private(set) var statusText = "Starting pi --session…"
    /// Live zoom multiplier for the SwiftTerm grid font. Bound to
    /// `PickyFontScales.minimum/maximum` and rounded to one decimal so ⌘+ taps
    /// don't drift. Persisted via `fontScalePersister` whenever the user changes it.
    @Published private(set) var fontScale: Double

    let title: String
    let sessionFilePath: String
    let cwd: String?

    private weak var terminalView: LocalProcessTerminalView?
    private var didStartProcess = false
    private let exitSync: PickyTerminalExitSyncScheduler
    private let fontScalePersister: PickyTerminalFontScalePersister?

    init(
        title: String,
        sessionFilePath: String,
        cwd: String?,
        fontScalePersister: PickyTerminalFontScalePersister? = nil,
        exitSync: PickyTerminalExitSyncScheduler? = nil
    ) {
        self.title = title
        self.sessionFilePath = sessionFilePath
        self.cwd = cwd
        self.fontScalePersister = fontScalePersister
        self.exitSync = exitSync ?? PickyTerminalExitSyncScheduler()
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
        exitSync.markExited()
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

    private func startProcessIfNeeded(in terminalView: LocalProcessTerminalView) {
        guard !didStartProcess else { return }
        didStartProcess = true
        exitSync.markStarted()
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
                    .foregroundColor(DS.Colors.success)
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
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> PickySwiftTermView {
        let terminalView = PickySwiftTermView(frame: .zero)
        terminalView.processDelegate = context.coordinator
        terminalView.autoresizingMask = [.width, .height]
        terminalView.configurePickyAppearance(fontScale: model.fontScale)
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        model.attach(terminalView)
        return terminalView
    }

    func updateNSView(_ terminalView: PickySwiftTermView, context: Context) {
        terminalView.processDelegate = context.coordinator
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
