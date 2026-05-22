//
//  PickyDiffReviewClipboard.swift
//  Picky
//

import AppKit

struct PickyDiffReviewClipboard {
    static func read() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
