//
//  PickyToolResultPresentation.swift
//  Picky
//
//  Pure projection from a bounded tool result preview into either a stable
//  JSON tree or the existing plain-text fallback.
//

import CoreFoundation
import Foundation

struct PickyToolHistoryResult: Equatable {
    let text: String
    let isTruncated: Bool
    let isRepaired: Bool
}

enum PickyJSONResultState: Equatable {
    case json
    case repaired
    case partial
}

struct PickyJSONMember: Equatable, Identifiable {
    let key: String
    let node: PickyJSONNode

    var id: String { node.id }
}

struct PickyJSONNode: Equatable, Identifiable {
    indirect enum Value: Equatable {
        case object([PickyJSONMember])
        case array([PickyJSONNode])
        case string(String)
        case number(String)
        case boolean(Bool)
        case null
    }

    let id: String
    let value: Value

    var itemCount: Int? {
        switch value {
        case .object(let members): members.count
        case .array(let items): items.count
        default: nil
        }
    }

    var collectionName: String? {
        switch value {
        case .object: "object"
        case .array: "array"
        default: nil
        }
    }

    var scalarDisplayText: String? {
        switch value {
        case .string(let value): Self.quotedJSONString(value)
        case .number(let value): value
        case .boolean(let value): value ? "true" : "false"
        case .null: "null"
        case .object, .array: nil
        }
    }

    private static func quotedJSONString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2
        else { return "\"\(value)\"" }
        return String(encoded.dropFirst().dropLast())
    }
}

enum PickyToolResultPresentation: Equatable {
    case json(root: PickyJSONNode, state: PickyJSONResultState)
    case text(String, isTruncated: Bool)

    static func make(from result: PickyToolHistoryResult) -> PickyToolResultPresentation {
        guard looksLikeJSONObjectOrArray(result.text),
              let data = result.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = node(from: object, path: "$root")
        else {
            return .text(result.text, isTruncated: result.isTruncated)
        }

        let state: PickyJSONResultState = if result.isTruncated {
            .partial
        } else if result.isRepaired {
            .repaired
        } else {
            .json
        }
        return .json(root: root, state: state)
    }

    private static func looksLikeJSONObjectOrArray(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first == "{" || first == "["
    }

    private static func node(from value: Any, path: String) -> PickyJSONNode? {
        if let object = value as? [String: Any] {
            let members = object.keys.sorted().compactMap { key -> PickyJSONMember? in
                guard let rawValue = object[key],
                      let child = node(from: rawValue, path: "\(path)/\(escapePathComponent(key))")
                else { return nil }
                return PickyJSONMember(key: key, node: child)
            }
            guard members.count == object.count else { return nil }
            return PickyJSONNode(id: path, value: .object(members))
        }
        if let array = value as? [Any] {
            let children = array.enumerated().compactMap { index, child in
                node(from: child, path: "\(path)/\(index)")
            }
            guard children.count == array.count else { return nil }
            return PickyJSONNode(id: path, value: .array(children))
        }
        if let string = value as? String {
            return PickyJSONNode(id: path, value: .string(string))
        }
        if value is NSNull {
            return PickyJSONNode(id: path, value: .null)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return PickyJSONNode(id: path, value: .boolean(number.boolValue))
            }
            return PickyJSONNode(id: path, value: .number(number.stringValue))
        }
        return nil
    }

    private static func escapePathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
}
