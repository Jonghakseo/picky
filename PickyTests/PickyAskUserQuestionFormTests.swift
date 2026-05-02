//
//  PickyAskUserQuestionFormTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyAskUserQuestionFormTests {
    @Test func seedsDefaultsAndBuildsCompositeAnswer() throws {
        let questions = [
            PickyExtensionUiQuestion(
                id: "scope",
                type: .radio,
                prompt: "Scope?",
                label: nil,
                options: [PickyExtensionUiQuestionOption(value: "user", label: "User"), PickyExtensionUiQuestionOption(value: "project", label: "Project")],
                allowOther: true,
                required: true,
                placeholder: nil,
                defaultValue: .string("project")
            ),
            PickyExtensionUiQuestion(
                id: "items",
                type: .checkbox,
                prompt: "Items?",
                label: nil,
                options: [PickyExtensionUiQuestionOption(value: "rule", label: "Rule"), PickyExtensionUiQuestionOption(value: "gotcha", label: "Gotcha")],
                allowOther: true,
                required: true,
                placeholder: nil,
                defaultValue: .array([.string("rule")])
            ),
            PickyExtensionUiQuestion(
                id: "note",
                type: .text,
                prompt: "Note",
                label: nil,
                options: nil,
                allowOther: nil,
                required: false,
                placeholder: "optional",
                defaultValue: .string("  keep this  ")
            )
        ]
        var state = PickyAskUserQuestionFormState()

        state.seedDefaults(for: questions)
        state.otherValues["items"] = "custom"

        #expect(state.isSubmittable(questions: questions))
        #expect(state.answerObject(for: questions) == [
            "scope": .string("project"),
            "items": .array([.string("rule"), .string("custom")]),
            "note": .string("keep this")
        ])
    }

    @Test func validatesRequiredQuestionsAndSupportsOtherRadio() throws {
        let questions = [
            PickyExtensionUiQuestion(
                id: "choice",
                type: .radio,
                prompt: "Choice?",
                label: nil,
                options: [PickyExtensionUiQuestionOption(value: "a", label: "A")],
                allowOther: true,
                required: true,
                placeholder: nil,
                defaultValue: nil
            ),
            PickyExtensionUiQuestion(
                id: "comment",
                type: .text,
                prompt: "Comment?",
                label: nil,
                options: nil,
                allowOther: nil,
                required: true,
                placeholder: nil,
                defaultValue: nil
            )
        ]
        var state = PickyAskUserQuestionFormState()
        state.seedDefaults(for: questions)

        #expect(!state.isSubmittable(questions: questions))
        state.selectRadio(question: questions[0], index: 0, value: PickyAskUserQuestionFormState.otherSentinel)
        state.otherValues["choice"] = "custom choice"
        state.textValues["comment"] = " ready "

        #expect(state.isSubmittable(questions: questions))
        #expect(state.answerObject(for: questions) == [
            "choice": .string("custom choice"),
            "comment": .string("ready")
        ])
    }

    @Test func fallsBackToStableQuestionIndexesWhenIdsAreMissing() throws {
        let questions = [
            PickyExtensionUiQuestion(id: nil, type: .text, prompt: "First", label: nil, options: nil, allowOther: nil, required: false, placeholder: nil, defaultValue: nil),
            PickyExtensionUiQuestion(id: nil, type: .checkbox, prompt: "Second", label: nil, options: [PickyExtensionUiQuestionOption(value: "x", label: "X")], allowOther: false, required: false, placeholder: nil, defaultValue: nil)
        ]
        var state = PickyAskUserQuestionFormState()
        state.seedDefaults(for: questions)
        state.textValues["q1"] = "one"
        state.toggleCheckbox(question: questions[1], index: 1, value: "x")

        #expect(state.answerObject(for: questions) == [
            "q1": .string("one"),
            "q2": .array([.string("x")])
        ])
    }
}
