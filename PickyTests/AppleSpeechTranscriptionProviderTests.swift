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

    @Test func transcriptAccumulatorKeepsCumulativePartialResultsAsSingleDraft() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        #expect(accumulator.update(with: "앞부분 내용") == "앞부분 내용")
        #expect(accumulator.update(with: "앞부분 내용 중간 내용") == "앞부분 내용 중간 내용")
        #expect(accumulator.update(with: "앞부분 내용 중간 내용 마지막 내용") == "앞부분 내용 중간 내용 마지막 내용")
    }

    @Test func transcriptAccumulatorAppendsWhenLongRecognitionResetsToLastChunk() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        _ = accumulator.update(with: "첫 번째 문장입니다 두 번째 문장입니다 세 번째 문장입니다 네 번째 문장입니다")
        let transcript = accumulator.update(with: "다섯 번째 문장입니다 여섯 번째 문장입니다")

        #expect(transcript == "첫 번째 문장입니다 두 번째 문장입니다 세 번째 문장입니다 네 번째 문장입니다 다섯 번째 문장입니다 여섯 번째 문장입니다")
    }

    @Test func transcriptAccumulatorExtendsResetChunkWithoutDuplicatingOverlap() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        _ = accumulator.update(with: "첫 번째 문장입니다 두 번째 문장입니다 세 번째 문장입니다 네 번째 문장입니다")
        _ = accumulator.update(with: "다섯 번째 문장입니다")
        let transcript = accumulator.update(with: "다섯 번째 문장입니다 여섯 번째 문장입니다")

        #expect(transcript == "첫 번째 문장입니다 두 번째 문장입니다 세 번째 문장입니다 네 번째 문장입니다 다섯 번째 문장입니다 여섯 번째 문장입니다")
    }

    @Test func transcriptAccumulatorTreatsShortNonOverlappingUpdateAsRevision() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        _ = accumulator.update(with: "피키 열어")
        let transcript = accumulator.update(with: "피키로 열어")

        #expect(transcript == "피키로 열어")
    }
}
