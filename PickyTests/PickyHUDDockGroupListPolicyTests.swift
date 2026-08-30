//
//  PickyHUDDockGroupListPolicyTests.swift
//  PickyTests
//
//  Geometry contract for the dock group list panel: saturation, anchoring
//  against the folder tile, and on-screen clamping.
//

import AppKit
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
        let expectedHeight = PickyHUDDockGroupListPolicy.panelChromeHeight(metrics: metrics)
            + PickyHUDDockGroupListPolicy.rowStackHeight(
                rowCount: PickyHUDDockLayout.groupListMaxVisibleRows,
                metrics: metrics,
                fontScale: 1
            )
        #expect(eight.height == expectedHeight)
        #expect(eight.width == metrics.groupListPanelWidth)
    }

    @Test func contentFitWidthsGrowWithTextAndCapAtTheExistingGroupPanelWidth() {
        let shortRows = [
            PickyHUDDockGroupListPolicy.RowWidthContent(
                title: "A",
                subtitle: "now · src",
                isUnread: false
            ),
        ]
        let longRows = [
            PickyHUDDockGroupListPolicy.RowWidthContent(
                title: String(repeating: "Long pickle title ", count: 12),
                subtitle: "29 minutes ago · exceptionally-long-repository-folder-name",
                isUnread: true
            ),
        ]

        let shortListWidth = PickyHUDDockGroupListPolicy.panelWidth(
            groupName: "G",
            memberCount: 1,
            rows: shortRows,
            metrics: metrics,
            fontScale: 1
        )
        let longListWidth = PickyHUDDockGroupListPolicy.panelWidth(
            groupName: String(repeating: "Long group ", count: 12),
            memberCount: 1,
            rows: longRows,
            metrics: metrics,
            fontScale: 1
        )
        let shortPreviewWidth = PickyHUDDockGroupListPolicy.previewWidth(
            title: shortRows[0].title,
            subtitle: shortRows[0].subtitle,
            metrics: metrics,
            fontScale: 1
        )
        let longPreviewWidth = PickyHUDDockGroupListPolicy.previewWidth(
            title: longRows[0].title,
            subtitle: longRows[0].subtitle,
            metrics: metrics,
            fontScale: 1
        )

        #expect(shortListWidth < metrics.groupListPanelWidth)
        #expect(shortPreviewWidth < metrics.groupListPanelWidth)
        #expect(longListWidth == metrics.groupListPanelWidth)
        #expect(longPreviewWidth == metrics.groupListPanelWidth)
    }

    @Test func dynamicPanelWidthFlowsIntoTheTitleAndClickGeometry() {
        let fittedWidth = metrics.groupListPanelWidth - 80
        let panel = PickyHUDDockGroupListPolicy.panelSize(
            memberCount: 2,
            metrics: metrics,
            width: fittedWidth
        )
        let titleWidth = PickyHUDDockGroupListPolicy.titleColumnWidth(
            metrics: metrics,
            isUnread: false,
            fontScale: 1,
            panelWidth: panel.width
        )
        let clickWidth = PickyHUDDockGroupListPolicy.clickHostWidth(
            metrics: metrics,
            isUnread: false,
            fontScale: 1,
            panelWidth: panel.width
        )

        #expect(panel.width == fittedWidth)
        #expect(titleWidth < PickyHUDDockGroupListPolicy.titleColumnWidth(
            metrics: metrics,
            isUnread: false,
            fontScale: 1
        ))
        #expect(clickWidth < panel.width)
    }

    @Test func panelHeightContainsTokenizedRowContentAtEveryPresetAndAppFontScale() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for fontScale: CGFloat in [1, 1.3] {
                let panel = PickyHUDDockGroupListPolicy.panelSize(
                    memberCount: PickyHUDDockLayout.groupListMaxVisibleRows,
                    metrics: metrics,
                    fontScale: fontScale
                )
                let minimumContentHeight = PickyHUDDockGroupListPolicy.panelChromeHeight(metrics: metrics)
                    + PickyHUDDockGroupListPolicy.rowStackHeight(
                        rowCount: PickyHUDDockLayout.groupListMaxVisibleRows,
                        metrics: metrics,
                        fontScale: fontScale
                    )

                #expect(panel.height >= minimumContentHeight)
            }
        }
    }

    @Test func scrollingBeginsOnlyAfterTheVisibleRowCap() {
        #expect(PickyHUDDockGroupListPolicy.needsScroll(memberCount: 8) == false)
        #expect(PickyHUDDockGroupListPolicy.needsScroll(memberCount: 9))
    }

    @Test func rowContentHeightUsesTheBodyAndMetaRoles() {
        let fontScale: CGFloat = 1.3
        let titleFont = PickyHUDTypography.bodyNSFont(fontScale: fontScale)
        let subtitleFont = PickyHUDTypography.metaNSFont(fontScale: fontScale)
        let expected = lineHeight(titleFont)
            + metrics.groupListRowVerticalPadding
            + lineHeight(subtitleFont)
            + (metrics.groupListRowVerticalPadding * 2)

        #expect(
            PickyHUDDockGroupListPolicy.rowContentHeight(metrics: metrics, fontScale: fontScale) == expected
        )
    }

    @Test func rowsReserveSymmetricVerticalPaddingAtDefaultFontScale() {
        #expect(
            PickyHUDDockGroupListPolicy.rowHeight(metrics: metrics, fontScale: 1)
                >= PickyHUDDockGroupListPolicy.rowContentHeight(metrics: metrics, fontScale: 1)
        )
    }

    @Test func fixedTrailingRailContainsBothQuickActionsAndTheRestShortcut() {
        let fontScale: CGFloat = 1
        let shortcutWidth = PickyHUDDockGroupListPolicy.shortcutHintWidth(fontScale: fontScale)
        let railWidth = PickyHUDDockGroupListPolicy.trailingRailWidth(metrics: metrics)

        #expect(shortcutWidth == ceil(("⌘9" as NSString).size(withAttributes: [
            .font: PickyHUDTypography.badgeSemiboldNSFont(fontScale: fontScale),
        ]).width))
        #expect(railWidth >= shortcutWidth)
        #expect(railWidth == (metrics.groupListRowQuickActionSide * 2) + metrics.groupListRowQuickActionSpacing)
    }

    @Test func quickActionsKeepMinimumTargetsAndSymbolInsetsAtEveryPresetAndFontScale() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for fontScale: CGFloat in [1, 1.3] {
                let side = metrics.groupListRowQuickActionSide
                let symbolSize = metrics.groupListRowQuickActionSymbolSize

                #expect(side >= 20, "\(preset) at \(fontScale)x must keep a 20pt action target")
                #expect(symbolSize > 0)
                #expect(
                    symbolSize <= side * 0.5,
                    "\(preset) at \(fontScale)x must retain half the target for symbol insets"
                )
            }
        }
    }

    @Test func rowSpacingUsesTheSharedSpaceTwoStructuralMetric() {
        for preset in PickyHUDDockSizePreset.allCases {
            let presetMetrics = PickyHUDDockMetrics(preset: preset)
            #expect(presetMetrics.groupListRowSpacing == presetMetrics.groupListRowContentSpacing)
        }
    }

    @Test func rowsUseSymmetricSpaceTwoInsetsWithoutChangingPanelDimensions() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            #expect(metrics.groupListRowHorizontalPadding == metrics.groupListRowContentSpacing)

            for fontScale: CGFloat in [1, 1.3] {
                let panel = PickyHUDDockGroupListPolicy.panelSize(
                    memberCount: 4,
                    metrics: metrics,
                    fontScale: fontScale
                )
                let panelInnerWidth = panel.width - (metrics.groupListPanelPadding * 2)

                for isUnread in [false, true] {
                    let titleWidth = PickyHUDDockGroupListPolicy.titleColumnWidth(
                        metrics: metrics,
                        isUnread: isUnread,
                        fontScale: fontScale
                    )
                    let fixedWidths = metrics.groupListRowGlyphSide
                        + PickyHUDDockGroupListPolicy.trailingRailWidth(metrics: metrics)
                        + (isUnread ? 7 : 0)
                    let elementCount = isUnread ? 4 : 3
                    let spacing = CGFloat(elementCount - 1) * metrics.groupListRowContentSpacing
                    let renderedRowWidth = (metrics.groupListRowHorizontalPadding * 2)
                        + fixedWidths
                        + spacing
                        + titleWidth

                    #expect(titleWidth >= 0)
                    #expect(renderedRowWidth == panelInnerWidth)
                }

                #expect(panel.width == metrics.groupListPanelWidth)
                #expect(
                    panel.height == PickyHUDDockGroupListPolicy.panelChromeHeight(metrics: metrics)
                        + PickyHUDDockGroupListPolicy.rowStackHeight(
                            rowCount: 4,
                            metrics: metrics,
                            fontScale: fontScale
                        )
                )
            }
        }
    }

    @Test func clickHostsCoverTheRowOutsideTheFixedTrailingRailAtEveryPresetAndFontScale() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for fontScale: CGFloat in [1, 1.3] {
                for isUnread in [false, true] {
                    let leadingHostWidth = PickyHUDDockGroupListPolicy.clickHostWidth(
                        metrics: metrics,
                        isUnread: isUnread,
                        fontScale: fontScale
                    )
                    let trailingHostWidth = PickyHUDDockGroupListPolicy.trailingPaddingClickHostWidth(
                        metrics: metrics
                    )
                    let titleWidth = PickyHUDDockGroupListPolicy.titleColumnWidth(
                        metrics: metrics,
                        isUnread: isUnread,
                        fontScale: fontScale
                    )
                    let elementCount = isUnread ? 4 : 3
                    let expectedLeadingHostWidth = metrics.groupListRowHorizontalPadding
                        + metrics.groupListRowGlyphSide
                        + titleWidth
                        + (isUnread ? 7 : 0)
                        + CGFloat(elementCount - 1) * metrics.groupListRowContentSpacing

                    #expect(leadingHostWidth == expectedLeadingHostWidth)
                    #expect(trailingHostWidth == metrics.groupListRowHorizontalPadding)
                    #expect(
                        leadingHostWidth
                            + PickyHUDDockGroupListPolicy.trailingRailWidth(metrics: metrics)
                            + trailingHostWidth
                            == metrics.groupListPanelWidth - (metrics.groupListPanelPadding * 2)
                    )
                }
            }
        }
    }

    @Test func panelHeightIncludesInterRowSpacingWithoutClippingTheLastRow() {
        let rows = 3
        let panel = PickyHUDDockGroupListPolicy.panelSize(memberCount: rows, metrics: metrics)
        let expected = PickyHUDDockGroupListPolicy.panelChromeHeight(metrics: metrics)
            + (CGFloat(rows) * PickyHUDDockGroupListPolicy.rowHeight(metrics: metrics, fontScale: 1))
            + (CGFloat(rows - 1) * metrics.groupListRowSpacing)

        #expect(panel.height == expected)
    }

    @Test func panelSizeScalesWithTheDockPreset() {
        let mediumMetrics = PickyHUDDockMetrics(preset: .medium)
        let medium = PickyHUDDockGroupListPolicy.panelSize(
            memberCount: 8,
            metrics: mediumMetrics
        )

        // Medium is 0.86 of the authored width constant, rounded to the nearest point.
        let expectedWidth: CGFloat = 310
        #expect(medium.width == expectedWidth)
        #expect(medium.height > PickyHUDDockGroupListPolicy.panelChromeHeight(metrics: mediumMetrics))
    }

    @Test func outsideDismissalExcludesTheOwningTileAndLabelButNotAdjacentGaps() {
        let panelFrame = CGRect(x: 100, y: 100, width: 300, height: 360)
        // The interaction frame includes the 54pt tile, its 4pt gap, and the
        // label hit area below it. The panel's anchor remains tile-only.
        let owningInteractionFrame = CGRect(x: 20, y: 180, width: 54, height: 82)

        #expect(PickyHUDDockGroupListPolicy.shouldDismissForMouseDown(
            at: CGPoint(x: 45, y: 205),
            panelFrame: panelFrame,
            owningInteractionFrame: owningInteractionFrame
        ) == false)
        #expect(PickyHUDDockGroupListPolicy.shouldDismissForMouseDown(
            at: CGPoint(x: 45, y: 250),
            panelFrame: panelFrame,
            owningInteractionFrame: owningInteractionFrame
        ) == false)
        #expect(PickyHUDDockGroupListPolicy.shouldDismissForMouseDown(
            at: CGPoint(x: 80, y: 205),
            panelFrame: panelFrame,
            owningInteractionFrame: owningInteractionFrame
        ))
        #expect(PickyHUDDockGroupListPolicy.shouldDismissForMouseDown(
            at: CGPoint(x: 80, y: 80),
            panelFrame: panelFrame,
            owningInteractionFrame: owningInteractionFrame
        ))
        #expect(PickyHUDDockGroupListPolicy.shouldDismissForMouseDown(
            at: CGPoint(x: 120, y: 120),
            panelFrame: panelFrame,
            owningInteractionFrame: owningInteractionFrame
        ) == false)
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

    private func lineHeight(_ font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }
}
