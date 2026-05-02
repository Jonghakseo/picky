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

    @Test func transcriptAccumulatorTreatsLongSimilarIncomingAsRevisionNotAppend() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        _ = accumulator.update(with: "오늘 예약건 확인하고 결제 상태도 봐줘 그리고 고객 메모도 같이 확인해줘")
        let transcript = accumulator.update(with: "오늘 예약 건 확인하고 결제 상태도 봐줘 그리고 고객 메모도 같이 확인해줘")

        #expect(transcript == "오늘 예약 건 확인하고 결제 상태도 봐줘 그리고 고객 메모도 같이 확인해줘")
    }

    @Test func transcriptAccumulatorDoesNotGrowByAppendingRepeatedRevisions() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        _ = accumulator.update(with: "첫 번째 문장입니다 두 번째 문장입니다 세 번째 문장입니다 네 번째 문장입니다")
        _ = accumulator.update(with: "첫 번째 문장입니다 두 번째 문장입니다 세번째 문장입니다 네 번째 문장입니다")
        let transcript = accumulator.update(with: "첫 번째 문장입니다 두 번째 문장입니다 세번째 문장입니다 네 번째 문장입니다 다섯 번째 문장입니다")

        #expect(transcript == "첫 번째 문장입니다 두 번째 문장입니다 세번째 문장입니다 네 번째 문장입니다 다섯 번째 문장입니다")
    }

    @Test func transcriptAccumulatorIgnoresContainedOlderPartialResult() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        _ = accumulator.update(with: "첫 번째 문장입니다 두 번째 문장입니다 세 번째 문장입니다 네 번째 문장입니다")
        let transcript = accumulator.update(with: "첫 번째 문장입니다 두 번째 문장입니다")

        #expect(transcript == "첫 번째 문장입니다 두 번째 문장입니다 세 번째 문장입니다 네 번째 문장입니다")
    }
}
