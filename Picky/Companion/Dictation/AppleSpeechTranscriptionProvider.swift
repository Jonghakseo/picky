//
//  AppleSpeechTranscriptionProvider.swift
//  Picky
//
//  Local fallback transcription provider backed by Apple's Speech framework.
//

import AVFoundation
import Foundation
import Speech

struct AppleSpeechTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class AppleSpeechTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple Speech"
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let speechRecognizer = Self.makeBestAvailableSpeechRecognizer() else {
            throw AppleSpeechTranscriptionProviderError(message: "dictation is not available on this mac.")
        }

        return try AppleSpeechTranscriptionSession(
            speechRecognizer: speechRecognizer,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    static func preferredLocaleIdentifiers(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentLocaleIdentifier: String = Locale.autoupdatingCurrent.identifier
    ) -> [String] {
        let candidates = [
            environment["PICKY_SPEECH_LOCALE"],
            "ko-KR",
            currentLocaleIdentifier,
            "en-US"
        ]

        var seen = Set<String>()
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func makeBestAvailableSpeechRecognizer() -> SFSpeechRecognizer? {
        for localeIdentifier in preferredLocaleIdentifiers() {
            let preferredLocale = Locale(identifier: localeIdentifier)
            if let speechRecognizer = SFSpeechRecognizer(locale: preferredLocale) {
                print("🎙️ Apple Speech locale: \(preferredLocale.identifier)")
                return speechRecognizer
            }
        }

        return SFSpeechRecognizer()
    }
}

struct AppleSpeechTranscriptAccumulator {
    private var accumulatedText = ""

    mutating func update(with recognizedText: String) -> String {
        let incomingText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incomingText.isEmpty else { return accumulatedText }

        let existingText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingText.isEmpty else {
            accumulatedText = incomingText
            return accumulatedText
        }

        let normalizedIncomingText = incomingText.normalizedForTranscriptComparison
        let normalizedExistingText = existingText.normalizedForTranscriptComparison

        if normalizedIncomingText.hasPrefix(normalizedExistingText) {
            accumulatedText = incomingText
            return accumulatedText
        }

        if normalizedExistingText.hasSuffix(normalizedIncomingText)
            || normalizedExistingText.contains(normalizedIncomingText) {
            return accumulatedText
        }

        if let appendOnlySuffix = Self.appendOnlySuffix(from: incomingText, afterOverlappingWith: existingText) {
            accumulatedText = Self.joinTranscript(existingText, appendOnlySuffix)
            return accumulatedText
        }

        if Self.shouldTreatAsRevisionOfExistingResult(existingText: existingText, incomingText: incomingText) {
            accumulatedText = incomingText
            return accumulatedText
        }

        if Self.shouldAppendLikelyResetChunk(existingText: existingText, incomingText: incomingText) {
            accumulatedText = Self.joinTranscript(existingText, incomingText)
        } else {
            accumulatedText = incomingText
        }

        return accumulatedText
    }

    private static func appendOnlySuffix(from incomingText: String, afterOverlappingWith existingText: String) -> String? {
        let existingTokens = TranscriptToken.tokens(in: existingText)
        let incomingTokens = TranscriptToken.tokens(in: incomingText)
        guard !existingTokens.isEmpty, !incomingTokens.isEmpty else { return nil }

        let maximumOverlapCount = min(existingTokens.count, incomingTokens.count)
        guard maximumOverlapCount > 0 else { return nil }

        for overlapCount in stride(from: maximumOverlapCount, through: 1, by: -1) {
            let existingSuffix = existingTokens.suffix(overlapCount).map(\.normalized)
            let incomingPrefix = incomingTokens.prefix(overlapCount).map(\.normalized)
            guard existingSuffix == incomingPrefix else { continue }
            guard isSignificantOverlap(existingSuffix) else { continue }

            if overlapCount >= incomingTokens.count {
                return ""
            }

            let suffixStartIndex = incomingTokens[overlapCount].range.lowerBound
            return String(incomingText[suffixStartIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func shouldAppendLikelyResetChunk(existingText: String, incomingText: String) -> Bool {
        let existingTokens = TranscriptToken.tokens(in: existingText)
        let incomingTokens = TranscriptToken.tokens(in: incomingText)

        guard !incomingTokens.isEmpty else { return false }
        return existingText.count >= 40 || existingTokens.count >= 8
    }

    private static func shouldTreatAsRevisionOfExistingResult(existingText: String, incomingText: String) -> Bool {
        let existingTokens = TranscriptToken.tokens(in: existingText)
        let incomingTokens = TranscriptToken.tokens(in: incomingText)

        guard existingTokens.count >= 6, incomingTokens.count >= 6 else { return false }
        guard sharesStartingAnchor(existingTokens: existingTokens, incomingTokens: incomingTokens) else { return false }
        guard Double(incomingTokens.count) >= Double(existingTokens.count) * 0.75 else { return false }

        let sharedTokenCount = longestCommonSubsequenceLength(
            existingTokens.map(\.normalized),
            incomingTokens.map(\.normalized)
        )
        let shorterTokenCount = min(existingTokens.count, incomingTokens.count)
        guard shorterTokenCount > 0 else { return false }

        return Double(sharedTokenCount) / Double(shorterTokenCount) >= 0.72
    }

    private static func sharesStartingAnchor(existingTokens: [TranscriptToken], incomingTokens: [TranscriptToken]) -> Bool {
        guard let incomingFirstToken = incomingTokens.first?.normalized else { return false }
        let existingPrefixTokens = existingTokens.prefix(3).map(\.normalized)
        guard existingPrefixTokens.contains(incomingFirstToken) else { return false }

        if existingTokens.first?.normalized == incomingFirstToken {
            return true
        }

        guard incomingTokens.count > 1 else { return true }
        let incomingSecondToken = incomingTokens[1].normalized
        return existingPrefixTokens.contains(incomingSecondToken)
            || existingTokens.prefix(5).map(\.normalized).contains(incomingSecondToken)
    }

    private static func longestCommonSubsequenceLength(_ leftTokens: [String], _ rightTokens: [String]) -> Int {
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }

        var previousRow = Array(repeating: 0, count: rightTokens.count + 1)
        var currentRow = previousRow

        for leftIndex in leftTokens.indices {
            currentRow[0] = 0
            for rightOffset in rightTokens.indices {
                let column = rightOffset + 1
                if leftTokens[leftIndex] == rightTokens[rightOffset] {
                    currentRow[column] = previousRow[column - 1] + 1
                } else {
                    currentRow[column] = max(previousRow[column], currentRow[column - 1])
                }
            }
            swap(&previousRow, &currentRow)
        }

        return previousRow[rightTokens.count]
    }

    private static func isSignificantOverlap(_ normalizedTokens: [String]) -> Bool {
        let tokenCharacterCount = normalizedTokens.reduce(0) { $0 + $1.count }
        return normalizedTokens.count >= 2 || tokenCharacterCount >= 8
    }

    private static func joinTranscript(_ existingText: String, _ suffixText: String) -> String {
        let trimmedExistingText = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSuffixText = suffixText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingText.isEmpty else { return trimmedSuffixText }
        guard !trimmedSuffixText.isEmpty else { return trimmedExistingText }

        if trimmedExistingText.hasSuffix(" ") || trimmedExistingText.hasSuffix("\n") {
            return trimmedExistingText + trimmedSuffixText
        }

        return trimmedExistingText + " " + trimmedSuffixText
    }

    private struct TranscriptToken {
        let normalized: String
        let range: Range<String.Index>

        static func tokens(in text: String) -> [TranscriptToken] {
            text.split(whereSeparator: { $0.isWhitespace }).compactMap { tokenSlice in
                let normalizedToken = String(tokenSlice).normalizedForTranscriptTokenComparison
                guard !normalizedToken.isEmpty else { return nil }
                return TranscriptToken(normalized: normalizedToken, range: tokenSlice.startIndex..<tokenSlice.endIndex)
            }
        }
    }
}

private extension String {
    var normalizedForTranscriptComparison: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    var normalizedForTranscriptTokenComparison: String {
        trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
    }
}

private final class AppleSpeechTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.8

    private let recognitionRequest: SFSpeechAudioBufferRecognitionRequest
    private var recognitionTask: SFSpeechRecognitionTask?
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private var transcriptAccumulator = AppleSpeechTranscriptAccumulator()
    private var latestRecognizedText = ""
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false

    init(
        speechRecognizer: SFSpeechRecognizer,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        super.init()

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true

        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            self?.handleRecognitionEvent(result: result, error: error)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        recognitionRequest.append(audioBuffer)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true
        recognitionRequest.endAudio()
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func handleRecognitionEvent(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            latestRecognizedText = transcriptAccumulator.update(with: result.bestTranscription.formattedString)
            onTranscriptUpdate(latestRecognizedText)

            if result.isFinal {
                deliverFinalTranscriptIfNeeded(latestRecognizedText)
                return
            }
        }

        guard let error else { return }

        if hasRequestedFinalTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deliverFinalTranscriptIfNeeded(latestRecognizedText)
        } else {
            onError(error)
        }
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}
