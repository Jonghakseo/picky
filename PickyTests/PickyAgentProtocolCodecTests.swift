//
//  PickyAgentProtocolCodecTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyAgentProtocolCodecTests {
    @Test func arbitraryJSONPreservesBooleansNumbersAndNestedValues() throws {
        let json = Data("""
        {"enabled":true,"disabled":false,"count":1,"ratio":1.5,"name":"Pickle","items":[null,{"zero":0}]}
        """.utf8)
        let expected = JSONValue.object([
            "enabled": .bool(true),
            "disabled": .bool(false),
            "count": .number(1),
            "ratio": .number(1.5),
            "name": .string("Pickle"),
            "items": .array([.null, .object(["zero": .number(0)])])
        ])
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        #expect(try decoder.decode(JSONValue.self, from: json) == expected)
        let encoded = try JSONEncoder.pickyAgentProtocolEncoder().encode(expected)
        #expect(try decoder.decode(JSONValue.self, from: encoded) == expected)
    }

    @Test func datesDecodeWithOrWithoutFractionalSeconds() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let plain = try decoder.decode(Date.self, from: Data(#""1970-01-01T00:00:00Z""#.utf8))
        let fractional = try decoder.decode(Date.self, from: Data(#""1970-01-01T00:00:00.125Z""#.utf8))
        #expect(plain == Date(timeIntervalSince1970: 0))
        #expect(fractional == Date(timeIntervalSince1970: 0.125))
    }

    @Test func datesEncodeWithFractionalSecondsAndRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 0.125)
        let data = try JSONEncoder.pickyAgentProtocolEncoder().encode(date)
        #expect(String(data: data, encoding: .utf8) == #""1970-01-01T00:00:00.125Z""#)
        #expect(try JSONDecoder.pickyAgentProtocolDecoder().decode(Date.self, from: data) == date)
    }

    @Test func malformedDatesReportTheWireField() throws {
        struct Payload: Decodable { let createdAt: Date }
        do {
            _ = try JSONDecoder.pickyAgentProtocolDecoder().decode(
                Payload.self,
                from: Data(#"{"createdAt":"not-a-date"}"#.utf8)
            )
            Issue.record("Expected malformed wire date to be rejected")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.codingPath.map(\.stringValue) == ["createdAt"])
            #expect(context.debugDescription == "Invalid ISO8601 date: not-a-date")
        }
    }
}
