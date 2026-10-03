//
//  PickyAgentSettingsProtocol.swift
//  Picky
//
//  Codable app-daemon settings control protocol models.
//

import Foundation

enum PickySettingsRequestAction: String, Decodable, Equatable {
    case list
    case get
    case set
}

struct PickySettingsRequest: Decodable, Equatable {
    let requestId: String
    let action: PickySettingsRequestAction
    let key: String?
    let value: JSONValue?
    let toggle: Bool?
    let displayId: String?
    let caller: String?
}
