//
//  PickyAskUserQuestionFormTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyAskUserQuestionFormTests {
    @Test func omittedAllowOtherDefaultsToTrueWhileExplicitFalseDisablesIt() {
        let defaultQuestion = PickyExtensionUiQuestion(
            id: "default", type: .radio, prompt: "Default", label: nil,
            options: nil, allowOther: nil, required: false, placeholder: nil, defaultValue: nil
        )
        let fixedListQuestion = PickyExtensionUiQuestion(
            id: "fixed", type: .radio, prompt: "Fixed", label: nil,
            options: nil, allowOther: false, required: false, placeholder: nil, defaultValue: nil
        )

        #expect(defaultQuestion.allowsOther)
        #expect(!fixedListQuestion.allowsOther)
    }

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

    @Test func validatesEachRequiredQuestionIndependently() throws {
        let requiredQuestion = PickyExtensionUiQuestion(
            id: "required",
            type: .text,
            prompt: "Required",
            label: nil,
            options: nil,
            allowOther: nil,
            required: true,
            placeholder: nil,
            defaultValue: nil
        )
        let optionalQuestion = PickyExtensionUiQuestion(
            id: "optional",
            type: .text,
            prompt: "Optional",
            label: nil,
            options: nil,
            allowOther: nil,
            required: false,
            placeholder: nil,
            defaultValue: nil
        )
        var state = PickyAskUserQuestionFormState()

        #expect(!state.isRequiredSatisfied(question: requiredQuestion, index: 0))
        #expect(state.isRequiredSatisfied(question: optionalQuestion, index: 1))

        state.textValues["required"] = "answered"
        #expect(state.isRequiredSatisfied(question: requiredQuestion, index: 0))
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

    @Test func summarizeAnswerReturnsNilForCancelledRequests() throws {
        let request = PickyExtensionUiRequest(
            id: "ui-1",
            sessionId: "session-1",
            method: "askUserQuestion",
            title: nil,
            prompt: nil,
            description: nil,
            options: nil,
            questions: [],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(PickyAskUserQuestionFormState.summarizeAnswer(request: request, value: .object(["cancelled": .bool(true)])) == nil)
    }

    @Test func summarizeAnswerHandlesConfirmSelectAndInputMethods() throws {
        let confirmRequest = PickyExtensionUiRequest(
            id: "ui-confirm", sessionId: "session-1", method: "confirm",
            title: nil, prompt: nil, description: nil, options: nil, questions: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(PickyAskUserQuestionFormState.summarizeAnswer(request: confirmRequest, value: .bool(true)) == "Allowed")
        #expect(PickyAskUserQuestionFormState.summarizeAnswer(request: confirmRequest, value: .bool(false)) == nil)

        let selectRequest = PickyExtensionUiRequest(
            id: "ui-select", sessionId: "session-1", method: "select",
            title: nil, prompt: nil, description: nil, options: ["alpha", "beta"], questions: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(PickyAskUserQuestionFormState.summarizeAnswer(request: selectRequest, value: .string("  alpha  ")) == "alpha")

        let inputRequest = PickyExtensionUiRequest(
            id: "ui-input", sessionId: "session-1", method: "input",
            title: nil, prompt: nil, description: nil, options: nil, questions: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(PickyAskUserQuestionFormState.summarizeAnswer(request: inputRequest, value: .string("  hello world  ")) == "hello world")
        #expect(PickyAskUserQuestionFormState.summarizeAnswer(request: inputRequest, value: .string("   ")) == nil)
    }

    @Test func summarizeAnswerForSingleAskUserQuestionUsesOptionLabel() throws {
        let request = PickyExtensionUiRequest(
            id: "ui-form",
            sessionId: "session-1",
            method: "askUserQuestion",
            title: nil,
            prompt: nil,
            description: nil,
            options: nil,
            questions: [
                PickyExtensionUiQuestion(
                    id: "commit-confirm",
                    type: .radio,
                    prompt: "Continue?",
                    label: nil,
                    options: [
                        PickyExtensionUiQuestionOption(value: "commit", label: "Commit"),
                        PickyExtensionUiQuestionOption(value: "stop", label: "Stop and review")
                    ],
                    allowOther: false,
                    required: true,
                    placeholder: nil,
                    defaultValue: nil
                )
            ],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let answer: JSONValue = .object(["value": .object(["commit-confirm": .string("stop")])])
        #expect(PickyAskUserQuestionFormState.summarizeAnswer(request: request, value: answer) == "Stop and review")
    }

    @Test func summarizeAnswerForMultipleAskUserQuestionPrefixesPromptsAndJoinsWithMiddleDot() throws {
        let request = PickyExtensionUiRequest(
            id: "ui-multi",
            sessionId: "session-1",
            method: "askUserQuestion",
            title: nil,
            prompt: nil,
            description: nil,
            options: nil,
            questions: [
                PickyExtensionUiQuestion(
                    id: "scope", type: .radio, prompt: "Scope", label: nil,
                    options: [PickyExtensionUiQuestionOption(value: "user", label: "User"), PickyExtensionUiQuestionOption(value: "project", label: "Project")],
                    allowOther: false, required: true, placeholder: nil, defaultValue: nil
                ),
                PickyExtensionUiQuestion(
                    id: "items", type: .checkbox, prompt: "Items", label: nil,
                    options: [PickyExtensionUiQuestionOption(value: "rule", label: "Rule"), PickyExtensionUiQuestionOption(value: "gotcha", label: "Gotcha")],
                    allowOther: true, required: true, placeholder: nil, defaultValue: nil
                ),
                PickyExtensionUiQuestion(
                    id: "note", type: .text, prompt: "Note", label: nil,
                    options: nil, allowOther: nil, required: false, placeholder: nil, defaultValue: nil
                )
            ],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let answer: JSONValue = .object(["value": .object([
            "scope": .string("project"),
            "items": .array([.string("rule"), .string("gotcha")]),
            "note": .string(" keep this ")
        ])])

        #expect(PickyAskUserQuestionFormState.summarizeAnswer(request: request, value: answer) == "Scope: Project \u{00B7} Items: Rule, Gotcha \u{00B7} Note: keep this")
    }

    private static let releaseQuestions = [
        PickyExtensionUiQuestion(
            id: "version", type: .radio, prompt: "Version?", label: "Version",
            options: [PickyExtensionUiQuestionOption(value: "beta", label: "0.9.3-beta.2"), PickyExtensionUiQuestionOption(value: "stable", label: "0.9.3")],
            allowOther: nil, required: true, placeholder: nil, defaultValue: nil
        ),
        PickyExtensionUiQuestion(
            id: "notes", type: .checkbox, prompt: "Notes?", label: nil,
            options: [PickyExtensionUiQuestionOption(value: "lag", label: "Lag fix"), PickyExtensionUiQuestionOption(value: "menu", label: "Send menu")],
            allowOther: nil, required: true, placeholder: nil, defaultValue: nil
        )
    ]

    @Test func numberKeysPickOptionsAndTheSlotAfterTheLastOneIsTypeYourOwn() {
        let questions = Self.releaseQuestions
        var state = PickyAskUserQuestionFormState()
        state.seedDefaults(for: questions)

        let result1 = state.applyNumberKey(2, question: questions[0], index: 0)
        #expect(result1)
        #expect(state.answerObject(for: questions)["version"] == .string("stable"))
        let result2 = state.applyNumberKey(3, question: questions[0], index: 0)
        #expect(result2)
        #expect(state.isOtherSelected(question: questions[0], index: 0))
        let result3 = state.applyNumberKey(4, question: questions[0], index: 0)
        #expect(!result3)

        let result4 = state.applyNumberKey(1, question: questions[1], index: 1)
        #expect(result4)
        let result5 = state.applyNumberKey(1, question: questions[1], index: 1)
        #expect(result5)
        #expect(state.answerObject(for: questions)["notes"] == .array([]))
    }

    @Test func uncheckingTypeYourOwnDropsItsTextFromTheAnswer() {
        let questions = Self.releaseQuestions
        var state = PickyAskUserQuestionFormState()
        state.seedDefaults(for: questions)
        state.toggleCheckbox(question: questions[1], index: 1, value: "lag")
        state.toggleCheckbox(question: questions[1], index: 1, value: PickyAskUserQuestionFormState.otherSentinel)
        state.otherValues["notes"] = "Table rendering"

        #expect(state.answerObject(for: questions)["notes"] == .array([.string("lag"), .string("Table rendering")]))

        state.toggleCheckbox(question: questions[1], index: 1, value: PickyAskUserQuestionFormState.otherSentinel)
        #expect(state.answerObject(for: questions)["notes"] == .array([.string("lag")]))
    }

    @Test func stepperAdvancesOnlyPastSatisfiedQuestionsAndChipsJumpBackOnly() {
        let questions = Self.releaseQuestions
        var state = PickyAskUserQuestionFormState()
        state.seedDefaults(for: questions)
        var stepper = PickyAskUserQuestionStepper()

        let result6 = stepper.advance(state, questions: questions)
        #expect(!result6)
        state.selectRadio(question: questions[0], index: 0, value: "beta")
        let result7 = stepper.advance(state, questions: questions)
        #expect(result7)
        #expect(stepper.isLast(questions))
        #expect(!stepper.isPrimaryEnabled(state, questions: questions))

        stepper.jump(to: 1)
        #expect(stepper.index == 1)
        stepper.jump(to: 0)
        #expect(stepper.index == 0)
        #expect(state.displayAnswer(question: questions[0], index: 0)?.first == "0.9.3-beta.2")
    }

    @Test func previousStepChipCountsTheExtraChoices() {
        let questions = Self.releaseQuestions
        var state = PickyAskUserQuestionFormState()
        state.toggleCheckbox(question: questions[1], index: 1, value: "lag")
        state.toggleCheckbox(question: questions[1], index: 1, value: "menu")

        let answer = state.displayAnswer(question: questions[1], index: 1)
        #expect(answer?.first == "Lag fix")
        #expect(answer?.more == 1)
        #expect(state.displayAnswer(question: questions[0], index: 0) == nil)
    }

    @Test func questionMessagesDecodeTheRecordedAnswerRows() throws {
        let json = """
        {"id":"q1","kind":"agent_question","createdAt":"2026-05-01T00:00:00.000Z",
         "answerRows":[{"label":"Version","value":"0.9.3-beta.2"},{"label":"","value":"Lag fix"}]}
        """
        let message = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionMessage.self, from: Data(json.utf8))
        #expect(message.answerRows == [
            PickyQuestionAnswerRow(label: "Version", value: "0.9.3-beta.2"),
            PickyQuestionAnswerRow(label: "", value: "Lag fix")
        ])
    }
}
