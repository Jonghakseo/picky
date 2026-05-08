import AppKit
import SwiftUI

@main
final class DiffReviewPlaygroundApp: NSObject, NSApplicationDelegate {
    private var window: KeyHandlingWindow?
    private var store: DiffReviewStore?

    static func main() {
        let app = NSApplication.shared
        let delegate = DiffReviewPlaygroundApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMinimalMenu()

        let store = DiffReviewStore(source: .fromCommandLine())
        self.store = store

        let rootView = DiffReviewRootView(store: store)
            .preferredColorScheme(.dark)
        let hostingView = NSHostingView(rootView: rootView)

        let visibleFrame = Self.targetScreen()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(CGFloat(1500), visibleFrame.width - 80)
        let height = min(CGFloat(980), visibleFrame.height - 80)
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )

        let window = KeyHandlingWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Picky Diff Review Playground"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1)
        window.level = .normal
        window.collectionBehavior = []
        window.minSize = NSSize(width: 1180, height: 760)
        window.contentView = hostingView
        window.onCloseShortcut = { [weak window] in window?.performClose(nil) }
        window.onReloadShortcut = { [weak store] in store?.reload() }
        window.onCopyFeedbackShortcut = { [weak store] in store?.copyFeedbackPrompt() }
        self.window = window

        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { abs($0.frame.minX) < 1 && abs($0.frame.minY) < 1 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func installMinimalMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Diff Review Playground", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let close = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.target = nil
        fileMenu.addItem(close)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        for item in editMenu.items { item.target = nil }
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

final class KeyHandlingWindow: NSWindow {
    var onCloseShortcut: (() -> Void)?
    var onReloadShortcut: (() -> Void)?
    var onCopyFeedbackShortcut: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command), let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch characters {
        case "w":
            onCloseShortcut?()
            return true
        case "r":
            onReloadShortcut?()
            return true
        case "c" where event.modifierFlags.contains(.shift):
            onCopyFeedbackShortcut?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
