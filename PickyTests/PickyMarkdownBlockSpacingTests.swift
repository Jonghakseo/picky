//
//  PickyMarkdownBlockSpacingTests.swift
//  PickyTests
//
//  The spacing policy is the whole point of the markdown rhythm work: a single
//  constant made "gap above a heading" identical to "gap between two list
//  items", which is what flattened long replies into one slab. These tests pin
//  the relationships rather than the exact numbers wherever the relationship is
//  what carries the meaning.
//

import Foundation
import Testing
@testable import Picky

struct PickyMarkdownBlockSpacingTests {
    private let bubble = PickyMarkdownBlockSpacing.bubble
    private let report = PickyMarkdownBlockSpacing.report

    @Test func firstBlockHasNoGapAbove() {
        #expect(PickyMarkdownBlockSpacing.gap(from: nil, to: .paragraph, metrics: bubble) == 0)
        #expect(PickyMarkdownBlockSpacing.gap(from: nil, to: .heading, metrics: bubble) == 0)
    }

    @Test func headingDetachesFromWhatPrecedesAndBindsToWhatFollows() {
        for metrics in [bubble, report] {
            let above = PickyMarkdownBlockSpacing.gap(from: .paragraph, to: .heading, metrics: metrics)
            let below = PickyMarkdownBlockSpacing.gap(from: .heading, to: .paragraph, metrics: metrics)
            let betweenParagraphs = PickyMarkdownBlockSpacing.gap(
                from: .paragraph,
                to: .paragraph,
                metrics: metrics
            )
            // The gap above a heading must dominate, and the gap below it must
            // be tighter than ordinary prose, or the heading reads as floating
            // between two sections instead of introducing the next one.
            #expect(above > betweenParagraphs)
            #expect(below < betweenParagraphs)
        }
    }

    @Test func headingLeadingWinsOverEveryPreviousKind() {
        for previous in [PickyMarkdownBlockSpacing.Kind.paragraph, .bullet, .embedded, .heading] {
            #expect(
                PickyMarkdownBlockSpacing.gap(from: previous, to: .heading, metrics: bubble)
                    == bubble.headingLeading
            )
        }
    }

    @Test func consecutiveBulletsPackTighterThanTheProseAroundThem() {
        for metrics in [bubble, report] {
            let betweenBullets = PickyMarkdownBlockSpacing.gap(from: .bullet, to: .bullet, metrics: metrics)
            let intoList = PickyMarkdownBlockSpacing.gap(from: .paragraph, to: .bullet, metrics: metrics)
            let outOfList = PickyMarkdownBlockSpacing.gap(from: .bullet, to: .paragraph, metrics: metrics)
            #expect(betweenBullets < intoList)
            #expect(intoList < outOfList)
        }
    }

    @Test func tablesAndCodeUseTheEmbeddedGapOnBothSides() {
        #expect(
            PickyMarkdownBlockSpacing.gap(from: .paragraph, to: .embedded, metrics: bubble)
                == bubble.embedded
        )
        #expect(
            PickyMarkdownBlockSpacing.gap(from: .embedded, to: .paragraph, metrics: bubble)
                == bubble.embedded
        )
        #expect(
            PickyMarkdownBlockSpacing.gap(from: .embedded, to: .bullet, metrics: bubble)
                == bubble.embedded
        )
    }

    @Test func headingStillDetachesWhenItFollowsAnEmbeddedBlock() {
        // Regression guard for the bubble container, where a heading that opens
        // an inline run right after a table is the one boundary a generic
        // "block gap" constant would silently flatten.
        #expect(
            PickyMarkdownBlockSpacing.gap(from: .embedded, to: .heading, metrics: bubble)
                == bubble.headingLeading
        )
    }

    @Test func reportMetricsScaleAboveBubbleMetrics() {
        // The report column is wider and set at 15pt, so every gap has to grow
        // with the measure rather than inherit the bubble's compact rhythm.
        #expect(report.paragraph > bubble.paragraph)
        #expect(report.headingLeading > bubble.headingLeading)
        #expect(report.bullet > bubble.bullet)
        #expect(report.embedded > bubble.embedded)
    }
}
