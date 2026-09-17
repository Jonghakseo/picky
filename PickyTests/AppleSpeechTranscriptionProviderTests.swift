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

    @Test func recognitionStateReplacesEarlierPartialWithLatestCompleteResult() {
        var state = AppleSpeechRecognitionState()

        _ = state.update(with: "키 입력 모니터링 몰 로그 이런 걸로라도 내 키 입력 모니터링 블로그")
        _ = state.update(with: "내 키 입력 모니터링 블로그 이런 걸로라도 내용을")
        _ = state.update(with: "키 입력 모니터링 블로그 이런 걸로라도 내용을 찾을 수")
        let transcript = state.update(with: "키 입력 모니터링 블로그 이런 걸로라도 내용을 찾을 수가 없나")

        #expect(transcript == "키 입력 모니터링 블로그 이런 걸로라도 내용을 찾을 수가 없나")
    }

    @Test func recognitionStatePreservesIntentionalRepeatedSpeech() {
        var state = AppleSpeechRecognitionState()

        let transcript = state.update(with: "다시 확인해 줘 다시 확인해 줘")

        #expect(transcript == "다시 확인해 줘 다시 확인해 줘")
    }

    @Test func emptyRecognitionUpdateKeepsLatestCompleteResultForFinalFallback() {
        var state = AppleSpeechRecognitionState()

        _ = state.update(with: "마지막으로 인식된 문장")

        #expect(state.update(with: "  \n") == "마지막으로 인식된 문장")
    }
}
