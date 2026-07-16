//
//  PickyQuestionOptionsLayoutPolicy.swift
//  Picky
//
//  Layout policy for compact extension-ui select controls.
//

import Foundation

enum PickyQuestionOptionsLayout: Equatable {
    case inlineRow
    case stacked
}

enum PickyQuestionOptionsLayoutPolicy {
    /// Inline controls must fit alongside a Cancel action in the conversation
    /// bubble's narrowest supported width. The character-count heuristic keeps
    /// this deterministic without coupling the policy to a rendered font.
    static let maximumInlineOptionCount = 3
    static let maximumInlineOptionLabelCharacterCount = 8
    static let maximumInlineLabelCharacterCount = 18

    static func layout(for options: [String]) -> PickyQuestionOptionsLayout {
        guard options.count <= maximumInlineOptionCount,
              options.allSatisfy({ $0.count <= maximumInlineOptionLabelCharacterCount }),
              options.reduce(0, { $0 + $1.count }) <= maximumInlineLabelCharacterCount
        else {
            return .stacked
        }

        return .inlineRow
    }
}
