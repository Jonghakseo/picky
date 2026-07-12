//
//  PickySettingsSanitizerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite
struct PickySettingsSanitizerTests {
    @Test func masksTopLevelKeysContainingApiKeyFragment() throws {
        let input: [String: Any] = [
            "azureOpenAIAPIKey": "super-secret-key",
            "defaultCwd": "/tmp/work"
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        let sanitized = try PickySettingsSanitizer.sanitize(jsonData: data)
        let object = try #require(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])

        #expect((object["azureOpenAIAPIKey"] as? String)?.hasPrefix("<masked:") == true)
        #expect(object["defaultCwd"] as? String == "/tmp/work")
    }

    @Test func masksNestedSecrets() throws {
        let input: [String: Any] = [
            "voiceProvider": [
                "apiKey": "another-secret",
                "voice": "marin"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        let sanitized = try PickySettingsSanitizer.sanitize(jsonData: data)
        let object = try #require(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let nested = try #require(object["voiceProvider"] as? [String: Any])
        #expect((nested["apiKey"] as? String)?.hasPrefix("<masked:") == true)
        #expect(nested["voice"] as? String == "marin")
    }

    @Test func masksOpenAIAndElevenLabsApiKeyFields() throws {
        let input: [String: Any] = [
            "openAITTSAPIKey": "sk-tts-secret",
            "openAISTTAPIKey": "sk-stt-secret",
            "elevenLabsSTTAPIKey": "el-secret",
            "openAITTSVoice": "alloy"
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        let sanitized = try PickySettingsSanitizer.sanitize(jsonData: data)
        let object = try #require(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        #expect((object["openAITTSAPIKey"] as? String)?.hasPrefix("<masked:") == true)
        #expect((object["openAISTTAPIKey"] as? String)?.hasPrefix("<masked:") == true)
        #expect((object["elevenLabsSTTAPIKey"] as? String)?.hasPrefix("<masked:") == true)
        #expect(object["openAITTSVoice"] as? String == "alloy")
    }

    @Test func masksOpenAIBaseURLFields() throws {
        let input: [String: Any] = [
            "openAITTSBaseURL": "http://internal-proxy.local:5050",
            "openAISTTBaseURL": "http://10.0.0.5:8000",
            "openAITTSVoice": "alloy"
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        let sanitized = try PickySettingsSanitizer.sanitize(jsonData: data)
        let object = try #require(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        #expect((object["openAITTSBaseURL"] as? String)?.hasPrefix("<masked:") == true)
        #expect((object["openAISTTBaseURL"] as? String)?.hasPrefix("<masked:") == true)
        #expect(object["openAITTSVoice"] as? String == "alloy")
    }

    @Test func leavesEmptySecretsAsEmptyString() throws {
        let input: [String: Any] = ["azureOpenAIAPIKey": ""]
        let data = try JSONSerialization.data(withJSONObject: input)
        let sanitized = try PickySettingsSanitizer.sanitize(jsonData: data)
        let object = try #require(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        #expect(object["azureOpenAIAPIKey"] as? String == "")
    }

    @Test func recognizesMultipleKeyFragments() {
        #expect(PickySettingsSanitizer.shouldMask(key: "githubToken") == true)
        #expect(PickySettingsSanitizer.shouldMask(key: "userPassword") == true)
        #expect(PickySettingsSanitizer.shouldMask(key: "clientSecret") == true)
        #expect(PickySettingsSanitizer.shouldMask(key: "authorizationHeader") == true)
        #expect(PickySettingsSanitizer.shouldMask(key: "defaultCwd") == false)
        #expect(PickySettingsSanitizer.shouldMask(key: nil) == false)
    }

    @Test func reportsCharacterCountInMask() {
        let masked = PickySettingsSanitizer.maskedReplacement(for: "abcdef")
        #expect(masked == "<masked:6 chars>")
    }
}
