//
//  PickyPickleOpener.swift
//  Picky
//
//  How a main-conversation surface opens the Pickle an answered delegation
//  question created ("Open Pickle"). The dock owns Pickles, so the conversation
//  only asks the app to show one; the app decides how (unarchive, then present
//  the card in the HUD). A Pickle that is no longer on this Mac offers no link.
//
//  A class on purpose: views hold it as an input, and SwiftUI compares a
//  reference by identity. A struct of closures cannot be compared, so the Hub
//  transcript would re-render on every keystroke in its composer.
//

import Foundation

final class PickyPickleOpener {
    let canOpen: (String) -> Bool
    let open: (String) -> Void

    init(canOpen: @escaping (String) -> Bool, open: @escaping (String) -> Void) {
        self.canOpen = canOpen
        self.open = open
    }
}
