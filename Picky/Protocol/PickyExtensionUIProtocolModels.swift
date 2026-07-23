//
//  PickyExtensionUIProtocolModels.swift
//  Picky
//
//  Codable extension UI models shared with picky-agentd contract fixtures.
//

import Foundation

enum PickyExtensionNotifyType: String, Codable, Equatable {
    case info
    case warning
    case error
}

struct PickyExtensionUiRequest: Codable, Equatable, Identifiable {
    let id: String
    let sessionId: String
    let method: String
    let title: String?
    let prompt: String?
    let description: String?
    let options: [String]?
    let questions: [PickyExtensionUiQuestion]?
    let createdAt: Date
    let text: String?
    let notifyType: PickyExtensionNotifyType?

    init(
        id: String,
        sessionId: String,
        method: String,
        title: String? = nil,
        prompt: String? = nil,
        description: String? = nil,
        options: [String]? = nil,
        questions: [PickyExtensionUiQuestion]? = nil,
        createdAt: Date,
        text: String? = nil,
        notifyType: PickyExtensionNotifyType? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.method = method
        self.title = title
        self.prompt = prompt
        self.description = description
        self.options = options
        self.questions = questions
        self.createdAt = createdAt
        self.text = text
        self.notifyType = notifyType
    }
}

struct PickyExtensionUiQuestion: Codable, Equatable, Identifiable {
    let id: String?
    let type: PickyExtensionUiQuestionType
    let prompt: String?
    let label: String?
    let options: [PickyExtensionUiQuestionOption]?
    let allowOther: Bool?
    let required: Bool?
    let placeholder: String?
    let defaultValue: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, type, prompt, label, options, allowOther, required, placeholder
        case defaultValue = "default"
    }

    /// An omitted value preserves the interactive form's default Other input.
    var allowsOther: Bool { allowOther ?? true }

}

enum PickyExtensionUiQuestionType: String, Codable, Equatable {
    case radio, checkbox, text
}

struct PickyExtensionUiQuestionOption: Codable, Equatable, Identifiable {
    let value: String
    let label: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case value, label, description
    }

    var id: String { value }

    init(value: String, label: String, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
            self.label = value
            self.description = nil
            return
        }
        let object = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try object.decode(String.self, forKey: .value)
        self.label = try object.decode(String.self, forKey: .label)
        self.description = try object.decodeIfPresent(String.self, forKey: .description)
    }
}
