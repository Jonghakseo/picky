//
//  PickyToolResultPresentationTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyToolResultPresentationTests {
    @Test func parsesObjectWithDeterministicKeyOrderAndStablePathIDs() throws {
        let presentation = PickyToolResultPresentation.make(from: .init(
            text: #"{"z":1,"a":{"nested":true}}"#,
            isTruncated: false,
            isRepaired: false
        ))

        guard case let .json(root, state) = presentation,
              case let .object(members) = root.value
        else {
            Issue.record("Expected JSON object presentation")
            return
        }

        #expect(state == .json)
        #expect(root.id == "$root")
        #expect(members.map(\.key) == ["a", "z"])
        #expect(members.map(\.id) == ["$root/a", "$root/z"])
        guard case let .object(nested) = members[0].node.value else {
            Issue.record("Expected nested object")
            return
        }
        #expect(nested.first?.id == "$root/a/nested")
        #expect(nested.first?.node.scalarDisplayText == "true")
    }

    @Test func parsesArrayScalarTypesWithoutConfusingBooleansAndNumbers() throws {
        let presentation = PickyToolResultPresentation.make(from: .init(
            text: #"[true,12,"text",null]"#,
            isTruncated: false,
            isRepaired: false
        ))

        guard case let .json(root, _) = presentation,
              case let .array(items) = root.value
        else {
            Issue.record("Expected JSON array presentation")
            return
        }

        #expect(items.map(\.scalarDisplayText) == ["true", "12", #""text""#, "null"])
        #expect(items.map(\.id) == ["$root/0", "$root/1", "$root/2", "$root/3"])
    }

    @Test func partialStateTakesPrecedenceOverRepairState() {
        let partial = PickyToolResultPresentation.make(from: .init(
            text: #"{"items":[]}"#,
            isTruncated: true,
            isRepaired: true
        ))
        let repaired = PickyToolResultPresentation.make(from: .init(
            text: #"{"items":[]}"#,
            isTruncated: false,
            isRepaired: true
        ))

        guard case let .json(_, partialState) = partial,
              case let .json(_, repairedState) = repaired
        else {
            Issue.record("Expected JSON presentations")
            return
        }
        #expect(partialState == .partial)
        #expect(repairedState == .repaired)
    }

    @Test func invalidOrPlainResultsPreserveTextFallback() {
        #expect(PickyToolResultPresentation.make(from: .init(
            text: "plain output",
            isTruncated: false,
            isRepaired: false
        )) == .text("plain output", isTruncated: false))

        #expect(PickyToolResultPresentation.make(from: .init(
            text: #"{"broken": "value""#,
            isTruncated: true,
            isRepaired: false
        )) == .text(#"{"broken": "value""#, isTruncated: true))
    }

    @Test func emptyCollectionsRemainStructuredWithZeroItems() {
        let object = PickyToolResultPresentation.make(from: .init(text: "{}", isTruncated: false, isRepaired: false))
        let array = PickyToolResultPresentation.make(from: .init(text: "[]", isTruncated: false, isRepaired: false))

        guard case let .json(objectRoot, _) = object,
              case let .json(arrayRoot, _) = array
        else {
            Issue.record("Expected empty JSON collections")
            return
        }
        #expect(objectRoot.itemCount == 0)
        #expect(arrayRoot.itemCount == 0)
    }
}
