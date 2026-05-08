import AppKit
import XCTest
@testable import DiffReviewPlayground

@MainActor
final class AppKitDiffFilesChangedViewTests: XCTestCase {
    func testDiffTableAllowsCommentTextViewToBecomeFirstResponder() {
        let tableView = DiffReviewTableView()
        let textView = NSTextView()

        XCTAssertTrue(tableView.validateProposedFirstResponder(textView, for: nil))
    }

    func testDiffTableAllowsNestedCommentEditorControlsToBecomeFirstResponder() {
        let tableView = DiffReviewTableView()
        let container = NSView()
        let textView = NSTextView()
        container.addSubview(textView)

        XCTAssertTrue(tableView.validateProposedFirstResponder(container, for: nil))
    }

    func testDiffTableAllowsCommentActionButtonsInsideRows() {
        let tableView = DiffReviewTableView()
        let button = NSButton(title: "Add comment", target: nil, action: nil)

        XCTAssertTrue(tableView.validateProposedFirstResponder(button, for: nil))
    }
}
