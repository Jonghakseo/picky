//
//  PickyAskUserQuestionForm.swift
//  Picky
//
//  Pure state and answer builder for askUserQuestion extension UI forms.
//

import Foundation

struct PickyAskUserQuestionFormState: Equatable {
    static let otherSentinel = "__picky_other__"

    var radioValues: [String: String] = [:]
    var checkboxValues: [String: Set<String>] = [:]
    var textValues: [String: String] = [:]
    var otherValues: [String: String] = [:]

    mutating func seedDefaults(for questions: [PickyExtensionUiQuestion]) {
        for (index, question) in questions.enumerated() {
            let key = Self.key(for: question, index: index)
            switch question.type {
            case .radio:
                if radioValues[key] == nil, case .string(let value)? = question.defaultValue {
                    radioValues[key] = value
                }
            case .checkbox:
                if checkboxValues[key] == nil {
                    if case .array(let values)? = question.defaultValue {
                        checkboxValues[key] = Set(values.compactMap { value in
                            if case .string(let string) = value { return string }
                            return nil
                        })
                    } else {
                        checkboxValues[key] = []
                    }
                }
            case .text:
                if textValues[key] == nil, case .string(let value)? = question.defaultValue {
                    textValues[key] = value
                }
            }
        }
    }

    mutating func selectRadio(question: PickyExtensionUiQuestion, index: Int, value: String) {
        radioValues[Self.key(for: question, index: index)] = value
    }

    mutating func toggleCheckbox(question: PickyExtensionUiQuestion, index: Int, value: String) {
        let key = Self.key(for: question, index: index)
        var selected = checkboxValues[key] ?? []
        if selected.contains(value) {
            selected.remove(value)
        } else {
            selected.insert(value)
        }
        checkboxValues[key] = selected
    }

    func isSubmittable(questions: [PickyExtensionUiQuestion]) -> Bool {
        for (index, question) in questions.enumerated() where question.required ?? true {
            let key = Self.key(for: question, index: index)
            switch question.type {
            case .radio:
                if radioAnswer(forKey: key).isEmpty { return false }
            case .checkbox:
                if checkboxAnswer(forKey: key).isEmpty { return false }
            case .text:
                if (textValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            }
        }
        return true
    }

    func answerObject(for questions: [PickyExtensionUiQuestion]) -> [String: JSONValue] {
        var answer: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() {
            let key = Self.key(for: question, index: index)
            switch question.type {
            case .radio:
                let value = radioAnswer(forKey: key)
                answer[key] = value.isEmpty ? .null : .string(value)
            case .checkbox:
                answer[key] = .array(checkboxAnswer(forKey: key).map(JSONValue.string))
            case .text:
                answer[key] = .string((textValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return answer
    }

    static func key(for question: PickyExtensionUiQuestion, index: Int) -> String {
        let trimmed = question.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return "q\(index + 1)"
    }

    private func radioAnswer(forKey key: String) -> String {
        let selected = radioValues[key] ?? ""
        if selected == Self.otherSentinel {
            return (otherValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkboxAnswer(forKey key: String) -> [String] {
        var selected = Array(checkboxValues[key] ?? []).sorted()
        let other = (otherValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !other.isEmpty { selected.append(other) }
        return selected
    }
}
