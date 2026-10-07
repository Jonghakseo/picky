//
//  PickyHoverTrackerTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

/// Scrolling content under a stationary pointer must not leave rows hovered.
/// Before the fix every row the pointer crossed kept its hover UI, because the
/// rebuilt tracking area swallowed the `mouseExited`.
@MainActor
struct PickyHoverTrackerTests {
    /// A horizontal 120pt viewport over five 60pt dock rows, with the pointer
    /// fixed at x=30 in the viewport.
    /// The window is never ordered on screen; it only gives the views real
    /// window coordinates and a visible rect clipped by the scroll view.
    private func makeDock(pointerX: CGFloat = 30) -> (NSScrollView, [PickyHUDDockIconClickNSView], () -> [[Bool]]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        scrollView.documentView = document
        window.contentView = scrollView

        final class Log { var changes: [[Bool]] = Array(repeating: [], count: 5) }
        let log = Log()
        var coordinators: [PickyHUDDockIconClickHost.Coordinator] = []
        var rows: [PickyHUDDockIconClickNSView] = []
        for index in 0..<5 {
            let row = PickyHUDDockIconClickNSView(frame: NSRect(x: CGFloat(index) * 60, y: 0, width: 60, height: 60))
            let coordinator = PickyHUDDockIconClickHost.Coordinator()
            coordinator.onHoverChanged = { log.changes[index].append($0) }
            row.coordinator = coordinator
            row.hoverTracker.pointerLocation = { _ in NSPoint(x: pointerX, y: 30) }
            document.addSubview(row)
            rows.append(row)
            coordinators.append(coordinator)
        }
        return (scrollView, rows, { _ = (coordinators, window); return log.changes })
    }

    private func enterEvent() throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 30, y: 30),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }

    @Test func scrollingARowOutFromUnderAStationaryPointerClearsItsHover() throws {
        let (scrollView, rows, changes) = makeDock()
        // AppKit reports the pointer entering row 0, then rows 1 and 2 as the
        // content scrolls under it; no exits arrive for the rows it left.
        rows[0].mouseEntered(with: try enterEvent())
        scrollView.contentView.scroll(to: NSPoint(x: 60, y: 0))
        rows[1].mouseEntered(with: try enterEvent())
        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        rows[2].mouseEntered(with: try enterEvent())

        #expect(rows.map(\.hoverTracker.isHovered) == [false, false, true, false, false])
        #expect(changes()[0] == [true, false])
        #expect(changes()[1] == [true, false])
        #expect(changes()[2] == [true])
    }

    @Test func aRowStillUnderThePointerKeepsHoverWithoutExtraCallbacks() throws {
        let (scrollView, rows, changes) = makeDock(pointerX: 50)
        rows[0].mouseEntered(with: try enterEvent())
        // Pointer sits at document x=55 after this scroll, still on row 0.
        scrollView.contentView.scroll(to: NSPoint(x: 5, y: 0))
        rows[0].updateTrackingAreas()

        #expect(rows[0].hoverTracker.isHovered)
        #expect(changes()[0] == [true])
        #expect(changes()[1].isEmpty)
    }

    @Test func aRowThatMovesAwayWithoutScrollingClearsOnGeometryChange() throws {
        let (_, rows, changes) = makeDock()
        rows[0].mouseEntered(with: try enterEvent())
        // A row inserted ahead pushes this one along; AppKit calls
        // updateTrackingAreas for the new geometry.
        rows[0].frame.origin.x = 180
        rows[0].updateTrackingAreas()

        #expect(!rows[0].hoverTracker.isHovered)
        #expect(changes()[0] == [true, false])
    }
}
