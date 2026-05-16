//
//  HTTPErrorBodyRedactionTests.swift
//  PickyTests
//
//  Verifies that HTTP error bodies surfaced via *.errorDescription are
//  passed through PickyDiagnosticTextRedactor and truncated to a safe
//  length, so that secrets echoed back by upstream providers (e.g. an
//  OpenAI 401 echoing the API key) never leak into the HUD or logs.
//

import Foundation
import Testing
@testable import Picky

@Suite("HTTP error body redaction")
struct HTTPErrorBodyRedactionTests {
    private static let leakedBody = """
    {"error":{"message":"Incorrect API key provided: sk-abc1234567890abcdef1234567890abcdef","type":"invalid_request_error","code":"invalid_api_key"}}
    """

    // 1) OpenAI: sk-... 패턴 마스킹
    @Test func openAIHTTPErrorBodyRedactsAPIKeyPattern() throws {
        let error = OpenAIAudioProviderError.httpError(statusCode: 401, body: Self.leakedBody)
        let description = try #require(error.errorDescription)
        #expect(description.contains("HTTP 401"))
        #expect(description.contains("sk-abc1234567890abcdef") == false)
        #expect(description.contains("<redacted>"))
    }

    // 2) Azure: sk-... 패턴 마스킹 (Azure는 보통 api-key 헤더이지만 응답 body가 동일 위험)
    @Test func azureHTTPErrorBodyRedactsAPIKeyPattern() throws {
        let error = AzureOpenAIAudioProviderError.httpError(statusCode: 401, body: Self.leakedBody)
        let description = try #require(error.errorDescription)
        #expect(description.contains("HTTP 401"))
        #expect(description.contains("sk-abc1234567890abcdef") == false)
        #expect(description.contains("<redacted>"))
    }

    // 3) ElevenLabs: 마찬가지
    @Test func elevenLabsHTTPErrorBodyRedactsAPIKeyPattern() throws {
        let error = ElevenLabsSpeechProviderError.httpError(statusCode: 401, body: Self.leakedBody)
        let description = try #require(error.errorDescription)
        #expect(description.contains("HTTP 401"))
        #expect(description.contains("sk-abc1234567890abcdef") == false)
        #expect(description.contains("<redacted>"))
    }

    // 4) 200자 초과 body는 잘림 + 말줄임표
    @Test func httpErrorBodyTruncatesLongPayloads() throws {
        let longBody = String(repeating: "abcde12345", count: 50) // 500 chars, no secrets
        let error = OpenAIAudioProviderError.httpError(statusCode: 500, body: longBody)
        let description = try #require(error.errorDescription)
        // truncated suffix should appear and total tail should not include the entire body
        #expect(description.hasSuffix("…"))
        // status prefix length plus 200 truncated chars plus the trailing ellipsis
        // is far smaller than the raw 500-char body — assert under 260 chars total.
        #expect(description.count < 260)
    }

    // 5) 짧은 깨끗한 body는 그대로 유지 (truncate 없음)
    @Test func shortCleanBodyIsPreservedWithoutTruncation() throws {
        let body = "model not found"
        let error = OpenAIAudioProviderError.httpError(statusCode: 404, body: body)
        let description = try #require(error.errorDescription)
        #expect(description.contains("model not found"))
        #expect(description.hasSuffix("…") == false)
    }

    // 6) 빈 body는 status code만 노출
    @Test func emptyBodyShowsOnlyStatusCode() throws {
        let error = OpenAIAudioProviderError.httpError(statusCode: 500, body: "")
        let description = try #require(error.errorDescription)
        #expect(description == "OpenAI request failed with HTTP 500.")
    }

    // 7) Authorization Bearer 패턴도 마스킹 (PickyDiagnosticTextRedactor가 처리)
    @Test func bearerHeaderInBodyIsRedacted() throws {
        let body = #"{"detail":"Authorization: Bearer abcDEF123ghiJKL456"}"#
        let error = OpenAIAudioProviderError.httpError(statusCode: 401, body: body)
        let description = try #require(error.errorDescription)
        #expect(description.contains("abcDEF123ghiJKL456") == false)
        #expect(description.contains("<redacted>"))
    }

    // 8) ElevenLabs STT (TTS와 별개 error type) 마스킹
    @Test func elevenLabsTranscriptionHTTPErrorBodyRedactsAPIKeyPattern() throws {
        let leakedBody = """
        {"error":{"message":"Incorrect API key provided: sk-abc1234567890abcdef1234567890abcdef","type":"invalid_request_error"}}
        """
        let error = ElevenLabsTranscriptionProviderError.httpError(statusCode: 401, body: leakedBody)
        let description = try #require(error.errorDescription)
        #expect(description.contains("HTTP 401"))
        #expect(description.contains("sk-abc1234567890abcdef") == false)
        #expect(description.contains("<redacted>"))
    }
}
