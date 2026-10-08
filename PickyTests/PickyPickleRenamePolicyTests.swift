//
//  PickyPickleRenamePolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyPickleRenamePolicyTests {
    @Test func acceptsATrimmedNameAndReportsItAsTheTitleToPersist() {
        #expect(PickyPickleRenamePolicy.normalizedTitle("  Research results  ") == .success("Research results"))
        #expect(PickyPickleRenamePolicy.normalizedTitle("새 이름") == .success("새 이름"))
    }

    @Test func rejectsNamesTheDaemonWouldAlsoReject() {
        // The daemon tests `/[\p{Cc}\p{Zl}\p{Zp}]/u` against the raw request,
        // so a trailing newline must fail here too instead of being trimmed
        // away into a name the two ends disagree about.
        #expect(PickyPickleRenamePolicy.normalizedTitle("Research results\n") == .failure(.controlCharacter))
        #expect(PickyPickleRenamePolicy.normalizedTitle("Research\tresults") == .failure(.controlCharacter))
        #expect(PickyPickleRenamePolicy.normalizedTitle("Line\u{2028}separator") == .failure(.controlCharacter))
        #expect(PickyPickleRenamePolicy.normalizedTitle("Paragraph\u{2029}separator") == .failure(.controlCharacter))
        #expect(PickyPickleRenamePolicy.normalizedTitle("   ") == .failure(.empty))
        #expect(PickyPickleRenamePolicy.normalizedTitle("") == .failure(.empty))
    }

    @Test func trimsExactlyWhatTheDaemonTrims() {
        // ECMAScript `trim()` removes U+FEFF and keeps U+200B. Foundation's
        // whitespace set does the opposite, so a name normalized here would
        // otherwise differ from the one the daemon stores.
        #expect(PickyPickleRenamePolicy.normalizedTitle("\u{FEFF}  Name  \u{FEFF}") == .success("Name"))
        #expect(PickyPickleRenamePolicy.normalizedTitle("\u{200B}Name\u{200B}") == .success("\u{200B}Name\u{200B}"))
    }

    @Test func acceptsFormatCharactersTheDaemonAccepts() {
        // `CharacterSet.controlCharacters` also contains Cf (format)
        // characters. Rejecting those would refuse names the CLI can still
        // create, so a left-to-right mark and a zero-width joiner stay legal.
        #expect(PickyPickleRenamePolicy.normalizedTitle("Hebrew \u{200E}name") == .success("Hebrew \u{200E}name"))
        #expect(PickyPickleRenamePolicy.normalizedTitle("👩‍💻 pairing") == .success("👩‍💻 pairing"))
    }

    @Test func countsCodePointsNotCharactersForTheLengthLimit() {
        let maximum = String(repeating: "가", count: 200)
        #expect(PickyPickleRenamePolicy.normalizedTitle(maximum) == .success(maximum))
        #expect(PickyPickleRenamePolicy.normalizedTitle(maximum + "가") == .failure(.tooLong(scalarCount: 201)))
        // One emoji is one code point on both ends, matching the daemon's
        // `[...title].length`.
        let emoji = String(repeating: "🥒", count: 200)
        #expect(PickyPickleRenamePolicy.normalizedTitle(emoji) == .success(emoji))
        #expect(PickyPickleRenamePolicy.normalizedTitle(emoji + "🥒") == .failure(.tooLong(scalarCount: 201)))
    }
}
