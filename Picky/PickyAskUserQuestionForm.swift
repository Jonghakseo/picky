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
            // Unchecking "Type your own" discards its text so it never rides along unseen.
            if value == Self.otherSentinel { otherValues[key] = nil }
        } else {
            selected.insert(value)
        }
        checkboxValues[key] = selected
    }

    func isOtherSelected(question: PickyExtensionUiQuestion, index: Int) -> Bool {
        let key = Self.key(for: question, index: index)
        switch question.type {
        case .radio: return radioValues[key] == Self.otherSentinel
        case .checkbox: return checkboxValues[key]?.contains(Self.otherSentinel) == true
        case .text: return false
        }
    }

    func isOptionSelected(question: PickyExtensionUiQuestion, index: Int, value: String) -> Bool {
        let key = Self.key(for: question, index: index)
        switch question.type {
        case .radio: return radioValues[key] == value
        case .checkbox: return checkboxValues[key]?.contains(value) == true
        case .text: return false
        }
    }

    /// Number key `number` (1-based) picks the matching option; the slot after the
    /// last option is "Type your own" when the question allows it.
    @discardableResult
    mutating func applyNumberKey(_ number: Int, question: PickyExtensionUiQuestion, index: Int) -> Bool {
        let options = question.options ?? []
        let value: String
        if options.indices.contains(number - 1) {
            value = options[number - 1].value
        } else if number == options.count + 1, question.allowsOther {
            value = Self.otherSentinel
        } else {
            return false
        }
        switch question.type {
        case .radio: selectRadio(question: question, index: index, value: value)
        case .checkbox: toggleCheckbox(question: question, index: index, value: value)
        case .text: return false
        }
        return true
    }

    /// Short answer for the "previous step" chip: the first chosen label and how many more.
    func displayAnswer(question: PickyExtensionUiQuestion, index: Int) -> (first: String, more: Int)? {
        let key = Self.key(for: question, index: index)
        let labels: [String]
        switch question.type {
        case .radio:
            labels = [Self.label(for: radioAnswer(forKey: key), options: question.options ?? [])]
        case .checkbox:
            labels = checkboxAnswer(forKey: key).map { Self.label(for: $0, options: question.options ?? []) }
        case .text:
            labels = [(textValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let nonEmpty = labels.filter { !$0.isEmpty }
        guard let first = nonEmpty.first else { return nil }
        return (first, nonEmpty.count - 1)
    }

    private static func label(for value: String, options: [PickyExtensionUiQuestionOption]) -> String {
        options.first(where: { $0.value == value })?.label ?? value
    }

    func isSubmittable(questions: [PickyExtensionUiQuestion]) -> Bool {
        questions.enumerated().allSatisfy { index, question in
            isRequiredSatisfied(question: question, index: index)
        }
    }

    func isRequiredSatisfied(question: PickyExtensionUiQuestion, index: Int) -> Bool {
        guard question.required ?? true else { return true }

        let key = Self.key(for: question, index: index)
        switch question.type {
        case .radio:
            return !radioAnswer(forKey: key).isEmpty
        case .checkbox:
            return !checkboxAnswer(forKey: key).isEmpty
        case .text:
            return !(textValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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

    /// Build a human-readable summary of the user's answer to an extension UI request.
    /// Returns `nil` for cancellations or when the answer carries no displayable content;
    /// callers can use the returned string to populate the Pickle card REQUEST line.
    static func summarizeAnswer(request: PickyExtensionUiRequest, value: JSONValue) -> String? {
        if case .object(let object) = value, object["cancelled"] == .bool(true) { return nil }

        switch request.method {
        case "confirm":
            if value == .bool(true) { return "Allowed" }
            if case .object(let object) = value, object["confirmed"] == .bool(true) { return "Allowed" }
            return nil
        case "select":
            guard case .string(let raw) = value else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case "input", "editor":
            guard case .string(let raw) = value else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case "askUserQuestion":
            guard case .object(let outer) = value, case .object(let answers)? = outer["value"] else { return nil }
            return summarizeAskUserQuestionAnswers(questions: request.questions ?? [], answers: answers)
        default:
            return nil
        }
    }

    private static func summarizeAskUserQuestionAnswers(questions: [PickyExtensionUiQuestion], answers: [String: JSONValue]) -> String? {
        var parts: [String] = []
        for (index, question) in questions.enumerated() {
            let questionKey = key(for: question, index: index)
            guard let raw = answers[questionKey], let formatted = formatAnswerValue(raw, options: question.options ?? []) else { continue }
            if questions.count == 1 { return formatted }
            let label = (question.prompt ?? question.label ?? questionKey).trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(label.isEmpty ? formatted : "\(label): \(formatted)")
        }
        let combined = parts.joined(separator: " · ")
        return combined.isEmpty ? nil : combined
    }

    private static func formatAnswerValue(_ value: JSONValue, options: [PickyExtensionUiQuestionOption]) -> String? {
        switch value {
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return options.first(where: { $0.value == trimmed })?.label ?? trimmed
        case .array(let items):
            let labels: [String] = items.compactMap { item in
                guard case .string(let raw) = item else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return nil }
                return options.first(where: { $0.value == trimmed })?.label ?? trimmed
            }
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        case .bool(let bool):
            return bool ? "Yes" : "No"
        case .number(let number):
            if number.rounded() == number { return String(Int(number)) }
            return String(number)
        case .null, .object:
            return nil
        }
    }

    private func radioAnswer(forKey key: String) -> String {
        let selected = radioValues[key] ?? ""
        if selected == Self.otherSentinel {
            return (otherValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkboxAnswer(forKey key: String) -> [String] {
        let chosen = checkboxValues[key] ?? []
        var selected = chosen.subtracting([Self.otherSentinel]).sorted()
        let other = (otherValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !other.isEmpty { selected.append(other) }
        return selected
    }
}

/// Step rule shared by the Pickle question bubble and the main Picky question
/// panel: two or more questions are answered one at a time.
struct PickyAskUserQuestionStepper: Equatable {
    var index = 0

    static func usesSteps(_ questions: [PickyExtensionUiQuestion]) -> Bool { questions.count > 1 }

    var isFirst: Bool { index == 0 }
    func isLast(_ questions: [PickyExtensionUiQuestion]) -> Bool { index >= questions.count - 1 }

    func current(_ questions: [PickyExtensionUiQuestion]) -> (question: PickyExtensionUiQuestion, index: Int)? {
        guard questions.indices.contains(index) else { return nil }
        return (questions[index], index)
    }

    func isCurrentSatisfied(_ form: PickyAskUserQuestionFormState, questions: [PickyExtensionUiQuestion]) -> Bool {
        guard let current = current(questions) else { return true }
        return form.isRequiredSatisfied(question: current.question, index: current.index)
    }

    /// Whether the primary action ("next" mid-way, otherwise "submit") is enabled.
    func isPrimaryEnabled(_ form: PickyAskUserQuestionFormState, questions: [PickyExtensionUiQuestion]) -> Bool {
        Self.usesSteps(questions) && !isLast(questions)
            ? isCurrentSatisfied(form, questions: questions)
            : form.isSubmittable(questions: questions)
    }

    @discardableResult
    mutating func advance(_ form: PickyAskUserQuestionFormState, questions: [PickyExtensionUiQuestion]) -> Bool {
        guard Self.usesSteps(questions), !isLast(questions), isCurrentSatisfied(form, questions: questions) else { return false }
        index += 1
        return true
    }

    mutating func back() {
        guard index > 0 else { return }
        index -= 1
    }

    /// Previous-answer chips jump back only; later steps open through "next".
    mutating func jump(to step: Int) {
        guard step >= 0, step < index else { return }
        index = step
    }
}
