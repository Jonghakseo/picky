//
//  PickyHUDDockGroupListPolicyTests.swift
//  PickyTests
//
//  Geometry contract for the dock group list panel: saturation, anchoring
//  against the folder tile, and on-screen clamping.
//

import CoreGraphics
import Foundation
import Testing
@testable import Picky

struct PickyHUDDockGroupListPolicyTests {
    private let metrics = PickyHUDDockMetrics(preset: .large)
    private let folder = CGRect(x: 4, y: 120, width: 54, height: 54)
    private let rail = CGRect(x: 0, y: 0, width: 62, height: 400)

    @Test func panelHeightGrowsPerRowThenSaturatesAtTheVisibleRowCap() {
        let one = PickyHUDDockGroupListPolicy.panelSize(memberCount: 1, metrics: metrics)
        let eight = PickyHUDDockGroupListPolicy.panelSize(memberCount: 8, metrics: metrics)
        let nine = PickyHUDDockGroupListPolicy.panelSize(memberCount: 9, metrics: metrics)
        let forty = PickyHUDDockGroupListPolicy.panelSize(memberCount: 40, metrics: metrics)

        #expect(one.height < eight.height)
        #expect(eight.height == nine.height)
        #expect(eight.height == forty.height)
        #expect(one.width == eight.width)
        // 8 + 8 padding, 22 header, 8 rows of 38 at scale 1.0.
        #expect(eight.height == 342)
        #expect(eight.width == 260)
    }

    @Test func panelSizeIsNeverNegativeForAnEmptyGroup() {
        let empty = PickyHUDDockGroupListPolicy.panelSize(memberCount: 0, metrics: metrics)

        let chromeOnly: CGFloat = (metrics.groupListPanelPadding * 2) + metrics.groupListHeaderHeight
        #expect(empty.height == chromeOnly)
        #expect(PickyHUDDockGroupListPolicy.needsScroll(memberCount: 8) == false)
        #expect(PickyHUDDockGroupListPolicy.needsScroll(memberCount: 9))
    }

    @Test func panelSizeScalesWithTheDockPreset() {
        let medium = PickyHUDDockGroupListPolicy.panelSize(
            memberCount: 8,
            metrics: PickyHUDDockMetrics(preset: .medium)
        )

        // Medium is 0.86 of the authored constants, not 1.0.
        #expect(medium.width == 224)
        #expect(medium.height == 297)
    }

    @Test func verticalDocksAnchorTheFolderTopAndOpenTowardTheScreenInterior() {
        let size = PickyHUDDockGroupListPolicy.panelSize(memberCount: 4, metrics: metrics)

        let left = PickyHUDDockGroupListPolicy.anchoredOrigin(
            folderFrame: folder,
            railFrame: rail,
            panelSize: size,
            dockSide: .left,
            panelGap: 10
        )
        let right = PickyHUDDockGroupListPolicy.anchoredOrigin(
            folderFrame: folder,
            railFrame: rail,
            panelSize: size,
            dockSide: .right,
            panelGap: 10
        )

        #expect(left.y == folder.minY)
        #expect(right.y == folder.minY)
        #expect(left.x == rail.maxX + 10)
        #expect(right.x == rail.minX - 10 - size.width)
        // The two sides mirror each other about the rail.
        #expect((left.x - rail.maxX) == (rail.minX - (right.x + size.width)))
    }

    @Test func horizontalDocksAnchorTheFolderLeadingEdgeOnTheCrossAxis() {
        let size = PickyHUDDockGroupListPolicy.panelSize(memberCount: 4, metrics: metrics)
        let horizontalRail = CGRect(x: 0, y: 0, width: 400, height: 62)
        let horizontalFolder = CGRect(x: 120, y: 4, width: 54, height: 54)

        let top = PickyHUDDockGroupListPolicy.anchoredOrigin(
            folderFrame: horizontalFolder,
            railFrame: horizontalRail,
            panelSize: size,
            dockSide: .top,
            panelGap: 10
        )
        let bottom = PickyHUDDockGroupListPolicy.anchoredOrigin(
            folderFrame: horizontalFolder,
            railFrame: horizontalRail,
            panelSize: size,
            dockSide: .bottom,
            panelGap: 10
        )

        #expect(top.x == horizontalFolder.minX)
        #expect(bottom.x == horizontalFolder.minX)
        #expect(top.y == horizontalRail.maxY + 10)
        #expect(bottom.y == horizontalRail.minY - 10 - size.height)
    }

    @Test func clampSlidesAlongTheRailAxisAndLeavesTheAnchoredAxisAlone() {
        let size = PickyHUDDockGroupListPolicy.panelSize(memberCount: 8, metrics: metrics)
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 500)
        let overflowing = CGPoint(x: 300, y: 400)

        let clamped = PickyHUDDockGroupListPolicy.clampedOrigin(
            overflowing,
            panelSize: size,
            bounds: bounds,
            dockSide: .left,
            margin: 8
        )

        #expect(clamped.x == overflowing.x)
        #expect(clamped.y == bounds.maxY - 8 - size.height)
        #expect(clamped.y + size.height <= bounds.maxY - 8)
    }

    @Test func clampNeverFlipsTheOpenDirectionForEitherOrientation() {
        let size = PickyHUDDockGroupListPolicy.panelSize(memberCount: 8, metrics: metrics)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)

        let vertical = PickyHUDDockGroupListPolicy.clampedOrigin(
            CGPoint(x: -50, y: -50),
            panelSize: size,
            bounds: bounds,
            dockSide: .right,
            margin: 8
        )
        let horizontal = PickyHUDDockGroupListPolicy.clampedOrigin(
            CGPoint(x: -50, y: -50),
            panelSize: size,
            bounds: bounds,
            dockSide: .bottom,
            margin: 8
        )

        // Only the rail primary axis moves; the anchored axis keeps its value
        // even when that value sits outside the bounds.
        #expect(vertical.x == -50)
        #expect(vertical.y == 8)
        #expect(horizontal.y == -50)
        #expect(horizontal.x == 8)
    }

    @Test func clampKeepsAPanelTallerThanTheBoundsPinnedAtTheLeadingMargin() {
        let size = PickyHUDDockGroupListPolicy.panelSize(memberCount: 8, metrics: metrics)
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)

        let clamped = PickyHUDDockGroupListPolicy.clampedOrigin(
            CGPoint(x: 10, y: 150),
            panelSize: size,
            bounds: bounds,
            dockSide: .left,
            margin: 8
        )

        #expect(clamped.y == 8)
    }
}
