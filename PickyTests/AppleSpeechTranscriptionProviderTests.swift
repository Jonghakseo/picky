//
//  AppleSpeechTranscriptionProviderTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct AppleSpeechTranscriptionProviderTests {
    @Test func koreanSpeechLocaleIsPreferredByDefault() {
        let locales = AppleSpeechTranscriptionProvider.preferredLocaleIdentifiers(
            environment: [:],
            currentLocaleIdentifier: "en-US"
        )

        #expect(locales == ["ko-KR", "en-US"])
        #expect(locales.first == "ko-KR")
    }

    @Test func speechLocaleEnvironmentOverrideWinsAndDeduplicates() {
        let locales = AppleSpeechTranscriptionProvider.preferredLocaleIdentifiers(
            environment: ["PICKY_SPEECH_LOCALE": "ja-JP"],
            currentLocaleIdentifier: "ko-KR"
        )

        #expect(locales == ["ja-JP", "ko-KR", "en-US"])
    }
}
