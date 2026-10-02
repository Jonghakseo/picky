//
//  PickyTerminalOverlay.swift
//  Picky
//
//  Shared SwiftTerm plumbing for Picky's in-app terminals: the SwiftTerm view
//  subclass, its process-host/delegate adapters, font resolution and zoom
//  persistence. The local shell panel (`PickySessionExtendedTerminalView`)
//  builds on these; `PickyPiTerminalCommand` only renders the external
//  `pi --session` resume command the HUD and Hub copy to the clipboard.
//

import AppKit
import CoreText
import Foundation
import SwiftTerm

enum PickyPiTerminalCommand {
    static func makeCliResumeCommand(sessionFilePath: String, cwd: String?) -> String {
        let workingDirectory = workingDirectory(from: cwd)
        return "cd \(shellQuoted(workingDirectory)) && pi --session \(shellQuoted(sessionFilePath))"
    }

    static func workingDirectory(from cwd: String?) -> String {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedCwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : trimmedCwd
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Window-scoped persistence hook so each open terminal panel can write its zoom
/// level back to the shared settings file the moment the user taps ⌘+ / ⌘-.
/// Mirrors `PickyMarkdownReportFontScalePersister` so both surfaces follow the
/// same pattern.
@MainActor
struct PickyTerminalFontScalePersister {
    let load: () -> Double
    let save: (Double) -> Void

    static func defaultSettings(settingsStore: PickySettingsStore = PickySettingsStore()) -> PickyTerminalFontScalePersister {
        let persistence = PickySettingsPersistenceCoordinator.shared(for: settingsStore)
        return PickyTerminalFontScalePersister(
            load: { settingsStore.load().fontScales.terminal },
            save: { newScale in
                persistence.enqueue { $0.fontScales.terminal = PickyFontScales.clamped(newScale) }
            }
        )
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
    func terminatePickyProcess()
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

    func terminatePickyProcess() {
        terminate()
    }
}

@MainActor
protocol PickyTerminalProcessEventHandling: AnyObject {
    func updateTerminalTitle(_ terminalTitle: String)
    func processExited(exitCode: Int32?)
}

/// SwiftTerm keeps this delegate weakly. The owning terminal model holds this
/// adapter so process-exit delivery survives SwiftUI representable replacement.
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
    // Gate 0 characterization: explicit `send(txt:)` and SwiftTerm terminal-protocol
    // replies both reach `LocalProcessTerminalView.send(source:data)` without origin metadata.
    // Do not add a final input gate here until a safe source distinction exists.
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
        // (e.g. dragging an image into the shell) were rejected at the AppKit level
        // before any text could reach the pty. Register here so every Picky terminal
        // surface accepts them.
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
    /// emacs word-motion escapes a shell's line editor does not interpret, so the
    /// keys look dead. SwiftTerm declares `keyDown` as `public` (not
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
