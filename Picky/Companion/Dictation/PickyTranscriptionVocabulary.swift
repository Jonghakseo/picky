//
//  PickyTranscriptionVocabulary.swift
//  Picky
//
//  User-editable spelling hints for prompt-capable STT providers.
//

import Foundation

/// Merges the user's "frequently used words" with the automatic session
/// keyterms (built-in product words plus frontmost app/window terms).
///
/// User terms come first because providers cap the number of prompt terms;
/// anything the user typed must survive that cap.
struct PickyTranscriptionVocabulary: Equatable {
    static let defaultTermsText = "Picky, Pickle"

    let userTerms: [String]
    let includesContextTerms: Bool

    init(termsText: String, includesContextTerms: Bool) {
        self.userTerms = Self.parseTerms(termsText)
        self.includesContextTerms = includesContextTerms
    }

    init(settings: PickySettings) {
        self.init(termsText: settings.sttVocabulary, includesContextTerms: settings.sttIncludesContextTerms)
    }

    /// Accepts commas (ASCII, full-width, ideographic) and newlines as separators.
    static func parseTerms(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;\n\r")
        var seen = Set<String>()
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func keyterms(merging sessionKeyterms: [String]) -> [String] {
        userTerms + (includesContextTerms ? sessionKeyterms : [])
    }
}
