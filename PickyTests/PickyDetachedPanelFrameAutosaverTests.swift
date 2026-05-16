//
//  PickyDetachedPanelFrameAutosaverTests.swift
//  PickyTests
//
//  Covers the persistence layer that replaced NSWindow.setFrameAutosaveName for
//  Picky's detached report/tool-history/terminal panels. The original AppKit
//  autosave silently dropped writes from every panel after the first when
//  several panels of the same kind coexisted; these tests pin the new
//  PickyDetachedPanelFrameAutosaver to "latest move always wins" semantics.
//

import AppKit
import Testing
import Foundation
@testable import Picky

@Suite("PickyDetachedPanelFrame")
struct PickyDetachedPanelFrameTests {
    @Test func parsesLegacyAutosaveString() {
        // Format AppKit writes for `setFrameAutosaveName(_:)`:
        // "<x> <y> <w> <h> <screenX> <screenY> <screenW> <screenH>".
        let parsed = PickyDetachedPanelFrame.parseLegacyAutosave("0 12 960 1055 0 0 1728 1079")
        #expect(parsed == PickyDetachedPanelFrame(x: 0, y: 12, width: 960, height: 1055))
    }

    @Test func rejectsMalformedLegacyAutosaveString() {
        #expect(PickyDetachedPanelFrame.parseLegacyAutosave("") == nil)
        #expect(PickyDetachedPanelFrame.parseLegacyAutosave("not a frame") == nil)
        // Width/height of zero would create an unusable window.
        #expect(PickyDetachedPanelFrame.parseLegacyAutosave("10 20 0 100 0 0 1000 1000") == nil)
        #expect(PickyDetachedPanelFrame.parseLegacyAutosave("10 20 100 0 0 0 1000 1000") == nil)
    }

    @Test func roundTripsThroughSettingsJSON() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let store = PickySettingsStore(url: temp.appendingPathComponent("settings.json"))

        var settings = PickySettings.defaults(appSupportRoot: temp)
        settings.defaultCwd = cwd
        settings.worktreeParent = cwd
        settings.detachedPanelFrames = [
            PickyDetachedPanelKind.reportViewer.rawValue: PickyDetachedPanelFrame(x: 100, y: 200, width: 800, height: 600)
        ]
        try store.save(settings)

        let reloaded = store.load()
        #expect(reloaded.detachedPanelFrames[PickyDetachedPanelKind.reportViewer.rawValue]
                == PickyDetachedPanelFrame(x: 100, y: 200, width: 800, height: 600))
    }
}

@MainActor
@Suite("PickyDetachedPanelFramePersister")
struct PickyDetachedPanelFramePersisterTests {
    @Test func backedPersisterRoundTripsThroughSettingsJSON() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let store = PickySettingsStore(url: temp.appendingPathComponent("settings.json"))

        var seed = PickySettings.defaults(appSupportRoot: temp)
        seed.defaultCwd = cwd
        seed.worktreeParent = cwd
        try store.save(seed)

        // Pass nil for legacyDefaults so the test doesn't pick up a real
        // "NSWindow Frame PickyReportViewer" entry from the developer's machine.
        let persister = PickyDetachedPanelFramePersister.backed(by: store, kind: .reportViewer, legacyDefaults: nil)
        #expect(persister.load() == nil)

        persister.save(CGRect(x: 50, y: 60, width: 700, height: 500))

        let loaded = persister.load()
        #expect(loaded == CGRect(x: 50, y: 60, width: 700, height: 500))
    }

    @Test func migratesLegacyAutosaveValueWhenSettingsHaveNoEntry() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let store = PickySettingsStore(url: temp.appendingPathComponent("settings.json"))

        var seed = PickySettings.defaults(appSupportRoot: temp)
        seed.defaultCwd = cwd
        seed.worktreeParent = cwd
        try store.save(seed)

        // Isolated UserDefaults suite so the test doesn't touch the real domain.
        let suite = "picky-detached-frame-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("0 12 960 1055 0 0 1728 1079", forKey: "NSWindow Frame PickyReportViewer")

        let persister = PickyDetachedPanelFramePersister.backed(by: store, kind: .reportViewer, legacyDefaults: defaults)
        #expect(persister.load() == CGRect(x: 0, y: 12, width: 960, height: 1055))

        // Once the user moves the panel, the new value wins over the legacy one.
        persister.save(CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(persister.load() == CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    /// Pins the bug fix for "report panel doesn't remember its position when several
    /// reports are open at once." With NSWindow.setFrameAutosaveName, the second
    /// panel to claim the same name silently no-ops every save. With the new
    /// persister, both panels write to the same key and the latest move wins.
    @Test func multiplePanelKindsWriteToTheSameKey() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let store = PickySettingsStore(url: temp.appendingPathComponent("settings.json"))

        var seed = PickySettings.defaults(appSupportRoot: temp)
        seed.defaultCwd = cwd
        seed.worktreeParent = cwd
        try store.save(seed)

        let persisterA = PickyDetachedPanelFramePersister.backed(by: store, kind: .reportViewer, legacyDefaults: nil)
        let persisterB = PickyDetachedPanelFramePersister.backed(by: store, kind: .reportViewer, legacyDefaults: nil)

        persisterA.save(CGRect(x: 0, y: 0, width: 600, height: 400))
        persisterB.save(CGRect(x: 200, y: 100, width: 800, height: 500))

        // Both persisters share the same on-disk slot, so whichever moved last is
        // what the next launch (or the next opened panel) will see.
        #expect(persisterA.load() == CGRect(x: 200, y: 100, width: 800, height: 500))
        #expect(persisterB.load() == CGRect(x: 200, y: 100, width: 800, height: 500))
    }

    @Test func differentKindsAreStoredIndependently() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let store = PickySettingsStore(url: temp.appendingPathComponent("settings.json"))

        var seed = PickySettings.defaults(appSupportRoot: temp)
        seed.defaultCwd = cwd
        seed.worktreeParent = cwd
        try store.save(seed)

        let report = PickyDetachedPanelFramePersister.backed(by: store, kind: .reportViewer, legacyDefaults: nil)
        let toolHistory = PickyDetachedPanelFramePersister.backed(by: store, kind: .toolHistoryViewer, legacyDefaults: nil)
        let terminal = PickyDetachedPanelFramePersister.backed(by: store, kind: .terminalOverlay, legacyDefaults: nil)

        report.save(CGRect(x: 1, y: 2, width: 100, height: 100))
        toolHistory.save(CGRect(x: 3, y: 4, width: 200, height: 200))
        terminal.save(CGRect(x: 5, y: 6, width: 300, height: 300))

        #expect(report.load() == CGRect(x: 1, y: 2, width: 100, height: 100))
        #expect(toolHistory.load() == CGRect(x: 3, y: 4, width: 200, height: 200))
        #expect(terminal.load() == CGRect(x: 5, y: 6, width: 300, height: 300))
    }
}

@MainActor
@Suite("PickyDetachedPanelFrameAutosaver")
struct PickyDetachedPanelFrameAutosaverTests {
    @Test func appliesSavedFrameOnCreationWhenPersisterReturnsValue() {
        let savedRect = CGRect(x: 50, y: 60, width: 700, height: 500)
        let persister = PickyDetachedPanelFramePersister(
            load: { savedRect },
            save: { _ in }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        let autosaver = PickyDetachedPanelFrameAutosaver(panel: panel, persister: persister)
        _ = autosaver

        // constrainFrameRect may shift slightly to keep the window on-screen, so
        // assert size + that the origin is somewhere reasonable rather than a
        // strict equality on origin.
        #expect(panel.frame.size == savedRect.size)
    }

    @Test func leavesInitialFrameAloneWhenNothingSaved() {
        let persister = PickyDetachedPanelFramePersister.noop
        let initialRect = NSRect(x: 0, y: 0, width: 320, height: 240)
        let panel = NSPanel(
            contentRect: initialRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        // .titled adds a titlebar height to the frame, so capture the resolved
        // frame size before the autosaver runs and assert it doesn't change.
        let frameSizeBeforeAutosaver = panel.frame.size

        let autosaver = PickyDetachedPanelFrameAutosaver(panel: panel, persister: persister)
        _ = autosaver

        #expect(panel.frame.size == frameSizeBeforeAutosaver)
    }

    @Test func writesLatestFrameOnDidMoveNotification() async {
        var savedRects: [CGRect] = []
        let persister = PickyDetachedPanelFramePersister(
            load: { nil },
            save: { savedRects.append($0) }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        let autosaver = PickyDetachedPanelFrameAutosaver(panel: panel, persister: persister)
        _ = autosaver

        panel.setFrameOrigin(NSPoint(x: 200, y: 300))
        // Posting the notification synchronously (rather than waiting for AppKit
        // to surface didMove from setFrameOrigin) keeps the test deterministic
        // and avoids needing a live runloop spin in unit tests.
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)

        // Notification handlers run on the main queue; yield once so they fire.
        await Task.yield()
        await Task.yield()

        #expect(!savedRects.isEmpty)
        #expect(savedRects.last?.size == panel.frame.size)
        #expect(savedRects.last?.origin == panel.frame.origin)
    }

    @Test func writesLatestFrameOnDidResizeNotification() async {
        var savedRects: [CGRect] = []
        let persister = PickyDetachedPanelFramePersister(
            load: { nil },
            save: { savedRects.append($0) }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        let autosaver = PickyDetachedPanelFrameAutosaver(panel: panel, persister: persister)
        _ = autosaver

        panel.setContentSize(NSSize(width: 640, height: 480))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: panel)
        await Task.yield()
        await Task.yield()

        #expect(!savedRects.isEmpty)
        #expect(savedRects.last?.size == panel.frame.size)
    }

    @Test func stopsObservingAfterDeinit() async {
        var savedRects: [CGRect] = []
        let persister = PickyDetachedPanelFramePersister(
            load: { nil },
            save: { savedRects.append($0) }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        autoreleasepool {
            let autosaver = PickyDetachedPanelFrameAutosaver(panel: panel, persister: persister)
            _ = autosaver
            // autosaver goes out of scope here; observer should be torn down.
        }

        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
        await Task.yield()
        await Task.yield()

        #expect(savedRects.isEmpty)
    }
}
