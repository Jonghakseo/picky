//
//  PickyBubbleTableLayoutTests.swift
//  PickyTests
//
//  Guards how markdown tables read inside agent bubbles: short cells stay on
//  one line, every column fits the bubble, narrow bubbles fall back to
//  per-row cards, and Korean wraps at word boundaries.
//

import AppKit
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyBubbleTableLayoutTests {
    private static let memoryTable = """
    | 내부 모듈 | 역할 |
    |---|---|
    | 장기 기억 | 명시적으로 저장한 규칙·선호·결정 |
    | 현재 대화 | VCC 압축, 원문 참조와 현재 세션 검색 |
    | 과거 대화 | 세션 간 색인·검색·원문 조회 |
    """

    private static let proposalTable = """
    | # | 제안 | 효과 | 비용 |
    |:-:|---|---|:-:|
    | 1 | 열 폭을 실제 셀 크기(`cell.cellSize`)로 측정 | 스크린샷 표가 한 줄로 정리됨 | 작음 |
    | 2 | 표 셀과 본문에 `.hangulWordPriority` 적용 | 단어 중간 줄바꿈 제거 | 작음 |
    | 3 | 브라우저식 폭 배분 도입: 각 열 최소 폭은 가장 긴 단어, 최대 폭은 한 줄 전체 길이로 두고 말풍선 폭 안에서 나눔 | 열이 많거나 긴 셀이 섞인 표가 읽힘 | 중간 |
    | 4 | 마크다운 정렬(`:--`, `--:`) 반영 | 비교표 가독성 | 중간 (지금은 파서가 정렬 정보를 버림) |
    """

    @Test func shortCellsStayOnOneLineWhenTheBubbleHasRoom() throws {
        let surface = layoutSurface(markdown: Self.memoryTable, width: 600)
        let fields = visibleTextFields(in: surface)
        #expect(fields.count == 8)

        for field in fields {
            let oneLine = PickyBubbleMarkdownTableCell.measuredContentHeight(for: field, width: .greatestFiniteMagnitude)
            let painted = PickyBubbleMarkdownTableCell.measuredContentHeight(for: field, width: field.frame.width)
            // Columns used to be sized from boundingRect, which leaves out the
            // cell's text padding, so "내부 모듈" wrapped its last syllable.
            #expect(painted <= oneLine, "\(field.stringValue) wrapped at width \(field.frame.width)")
        }
    }

    @Test func everyColumnFitsInsideAWideBubble() {
        let surface = layoutSurface(markdown: Self.proposalTable, width: 600)
        let bubble = surface.lastBubbleRect

        let strings = visibleTextFields(in: surface).map(\.stringValue)
        #expect(strings.filter { $0 == "비용" }.count == 1, "a wide bubble keeps the grid")
        for field in visibleTextFields(in: surface) {
            let frame = field.convert(field.bounds, to: surface)
            #expect(frame.maxX <= bubble.maxX + 0.5, "\(field.stringValue) is cut off at x=\(frame.maxX)")
        }
    }

    @Test func narrowBubbleShowsFourColumnTableAsCards() {
        let surface = layoutSurface(markdown: Self.proposalTable, width: 380)
        let bubble = surface.lastBubbleRect
        let fields = visibleTextFields(in: surface)
        let strings = fields.map(\.stringValue)

        // One card per row: the index joins the title and every other column
        // is labeled inside the card, so nothing scrolls out of sight.
        #expect(strings.contains("1. 열 폭을 실제 셀 크기(cell.cellSize)로 측정"))
        #expect(strings.filter { $0 == "효과" }.count == 4)
        #expect(strings.filter { $0 == "비용" }.count == 4)
        for field in fields {
            let frame = field.convert(field.bounds, to: surface)
            #expect(frame.maxX <= bubble.maxX + 0.5, "\(field.stringValue) is cut off at x=\(frame.maxX)")
        }
    }

    /// The bubble measures a table at its full content width, then gives the
    /// block only the width it reported. Laid out at that narrower width, the
    /// table must keep the form, and therefore the height, it was measured
    /// with; otherwise taller cards spill over the text below.
    @Test func tableKeepsItsMeasuredFormWhenGivenItsReportedWidth() {
        let tables: [(headers: [String], rows: [[String]])] = [
            (["전송", "클릭", "첫 업로드", "직전 사용자 입력"], [
                ["개선 제안 2", "13:30:38", "13:31:56", "13:31:55 개선 제안 3 클릭"],
                ["개선 제안 3", "13:31:55", "13:32:28", "13:32:28 오류 신고 클릭"],
                ["오류 신고", "13:32:28", "13:32:31", "클릭 직후라 3초 만에 완료"]
            ]),
            (["Name", "A", "B", "C"], [["card", "1", "2", "3"], ["deck", "4", "5", "6"]])
        ]
        for table in tables {
            for width in stride(from: CGFloat(300), through: 700, by: 1) {
                let view = PickyTableMarkdownBlockView(headers: table.headers, rows: table.rows)
                let measured = view.measuredSize(forWidth: width)
                view.frame = NSRect(x: 0, y: 0, width: ceil(measured.width), height: ceil(measured.height))
                view.layoutSubtreeIfNeeded()
                view.layout()
                for field in visibleTextFields(in: view) {
                    let frame = field.convert(field.bounds, to: view)
                    #expect(
                        frame.maxY <= view.bounds.height + 0.5,
                        "\(table.headers[0]) at \(width) laid out at \(view.bounds.width): \(field.stringValue) at y=\(frame.maxY) > \(view.bounds.height)"
                    )
                }
            }
        }
    }

    @Test func alignedDelimiterRowsParseAsTablesWithTheirAlignment() {
        let blocks = PickyReportMarkdownRenderer().blocks(from: """
        | # | Name | Cost |
        |:-:|-|--:|
        | 1 | Alpha | 10 |
        """)

        // Delimiters shorter than three dashes used to fall through to plain
        // paragraphs that showed the raw pipes.
        #expect(blocks == [
            .table(
                headers: ["#", "Name", "Cost"],
                rows: [["1", "Alpha", "10"]],
                alignments: [.center, .leading, .trailing]
            ),
        ])
    }

    @Test func centeredColumnRendersCentered() {
        let surface = layoutSurface(markdown: Self.proposalTable, width: 600)
        let index = visibleTextFields(in: surface).first { $0.stringValue == "1" }
        let style = index?.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.alignment == .center)
    }

    @Test func koreanBubbleTextWrapsBetweenWordsNotSyllables() {
        let text = "VCC 압축, 원문 참조와 현재 세션 검색"
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [.paragraph(text)], scale: 1)
        let string = attributed.string as NSString

        for width in stride(from: CGFloat(120), through: 220, by: 5) {
            let storage = NSTextStorage(attributedString: attributed)
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)
            layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, _, _, glyphs, _ in
                let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let end = NSMaxRange(characters)
                guard end < string.length else { return }
                let last = string.substring(with: NSRange(location: end - 1, length: 1))
                #expect(last == " ", "line broke inside a word at width \(width): \(string.substring(with: characters))")
            }
        }
    }

    // MARK: - Helpers

    private func layoutSurface(markdown: String, width: CGFloat) -> PickyAgentBubbleSurfaceNSView {
        let surface = PickyAgentBubbleSurfaceNSView()
        surface.configure(
            markdown: markdown,
            maxBubbleWidth: width,
            codeBlockMaxLines: 0,
            showsShortcutBadge: false,
            onOpenAsReport: nil,
            onCopyText: nil
        )
        surface.frame = NSRect(origin: .zero, size: surface.measuredSize(forRootWidth: width))
        surface.layoutSubtreeIfNeeded()
        return surface
    }

    private func firstView<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstView(of: type, in: subview) { return match }
        }
        return nil
    }

    private func visibleTextFields(in root: NSView) -> [NSTextField] {
        guard !root.isHidden else { return [] }
        var fields: [NSTextField] = []
        if let field = root as? NSTextField, !field.stringValue.isEmpty { fields.append(field) }
        for subview in root.subviews { fields.append(contentsOf: visibleTextFields(in: subview)) }
        return fields
    }
}
