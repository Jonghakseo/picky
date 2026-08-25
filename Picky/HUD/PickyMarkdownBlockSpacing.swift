//
//  PickyMarkdownBlockSpacing.swift
//  Picky
//
//  Vertical rhythm policy for rendered markdown, shared by the conversation
//  bubble and the report viewer.
//
//  Both renderers previously used a single constant for every block
//  transition, which made the gap between two paragraphs identical to the gap
//  above a heading and to the gap between two list items. With no proximity
//  signal left, a long reply reads as one undifferentiated slab. Keying the
//  gap on the (previous, current) pair lets headings detach from what precedes
//  them and attach to what follows, and lets list items pack tighter than the
//  prose around them.
//

import CoreGraphics

enum PickyMarkdownBlockSpacing {
    /// Block roles that affect spacing. Heading levels collapse into one case
    /// because the level already differentiates itself through type size.
    /// `embedded` covers tables and fenced code, which own their internal
    /// padding and only need breathing room from the surrounding prose.
    enum Kind: Equatable {
        case heading
        case paragraph
        case bullet
        case embedded
    }

    struct Metrics: Equatable {
        let paragraph: CGFloat
        let bullet: CGFloat
        let listLeading: CGFloat
        let headingLeading: CGFloat
        let headingTrailing: CGFloat
        let embedded: CGFloat
    }

    /// Conversation bubble at 13pt body in a narrow column.
    static let bubble = Metrics(
        paragraph: 10,
        bullet: 3,
        listLeading: 7,
        headingLeading: 18,
        headingTrailing: 4,
        embedded: 8
    )

    /// Report viewer at 15pt body in a wide column. Gaps scale with the longer
    /// measure, and headings detach further because the reader scrolls through
    /// sections rather than glancing at one reply.
    static let report = Metrics(
        paragraph: 14,
        bullet: 4,
        listLeading: 9,
        headingLeading: 26,
        headingTrailing: 6,
        embedded: 14
    )

    /// Gap to insert above `current`. Returns 0 for the first block so the
    /// renderer never has to special-case the leading edge.
    static func gap(from previous: Kind?, to current: Kind, metrics: Metrics) -> CGFloat {
        guard let previous else { return 0 }
        if current == .heading { return metrics.headingLeading }
        if previous == .heading { return metrics.headingTrailing }
        if previous == .embedded || current == .embedded { return metrics.embedded }
        switch (previous, current) {
        case (.bullet, .bullet): return metrics.bullet
        case (_, .bullet): return metrics.listLeading
        default: return metrics.paragraph
        }
    }
}
