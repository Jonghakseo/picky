//
//  OpenAIAudioConfiguration.swift
//  Picky
//
//  Shared configuration for direct OpenAI audio providers (api.openai.com).
//  Unlike the Azure variant, the base URL is fixed and the deployment/version
//  concepts don't exist — only the API key plus a model identifier.
//

import Foundation

struct OpenAIAudioConfiguration: Equatable {
    static let defaultBaseURL: URL = URL(string: "https://api.openai.com")!

    var apiKey: String?
    var baseURL: URL
    var requestTimeout: TimeInterval

    init(
        apiKey: String?,
        baseURL: URL = OpenAIAudioConfiguration.defaultBaseURL,
        requestTimeout: TimeInterval = 30
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    var isConfigured: Bool {
        apiKey != nil
    }

    var missingConfigurationExplanation: String? {
        guard !isConfigured else { return nil }
        return "OpenAI audio provider is missing: api key."
    }

    static func fromEnvironment(
        apiKeyOverride: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OpenAIAudioConfiguration {
        let apiKey = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? AzureOpenAIKeychainStore.value(for: "OPENAI_API_KEY", environment: environment)

        return OpenAIAudioConfiguration(
            apiKey: apiKey,
            baseURL: defaultBaseURL
        )
    }

    /// Parse a user-supplied base URL override. Returns nil if blank or unparseable;
    /// callers fall back to `defaultBaseURL` in that case. We deliberately do not
    /// validate scheme/host beyond what `URL(string:)` accepts so users can point at
    /// `http://localhost:5050` style proxies.
    static func parseBaseURLOverride(_ rawValue: String?) -> URL? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return nil
        }
        return stripTrailingV1(from: url)
    }

    /// Strip a single trailing `/v1` (with optional trailing slash) from the path. OpenAI-compatible
    /// proxies typically advertise their base URL with `/v1` appended (e.g. `http://localhost:5050/v1`),
    /// but `audioURL(forPath:)` always appends `/v1/...`. Without this normalization the request would
    /// hit `/v1/v1/audio/speech` and 404.
    private static func stripTrailingV1(from url: URL) -> URL {
        let path = url.path
        let candidates: [String] = ["/v1", "/v1/"]
        guard let suffix = candidates.first(where: { path.hasSuffix($0) }) else { return url }
        let trimmedPath = String(path.dropLast(suffix.count))
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.path = trimmedPath
        return components.url ?? url
    }

    func audioURL(forPath audioPath: String) -> URL {
        let normalizedPath = audioPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent(normalizedPath, isDirectory: false)
    }

    func configuredAPIKey() throws -> String {
        guard let apiKey else {
            throw OpenAIAudioProviderError.notConfigured(missingConfigurationExplanation ?? "OpenAI API key is missing.")
        }
        return apiKey
    }
}

enum OpenAIAudioProviderError: LocalizedError {
    case notConfigured(String)
    case noAudioCaptured
    case emptyResponse
    case httpError(statusCode: Int, body: String)
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message):
            return message
        case .noAudioCaptured:
            return "No audio was captured for OpenAI transcription."
        case .emptyResponse:
            return "OpenAI returned an empty audio response."
        case .httpError(let statusCode, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else {
                return "OpenAI request failed with HTTP \(statusCode)."
            }
            let normalizedBody = trimmedBody.replacingOccurrences(
                of: #"(?i)Authorization:\s*Bearer\s+[^\s,\"'}]+"#,
                with: "<redacted>",
                options: .regularExpression
            )
            let redactedBody = PickyDiagnosticTextRedactor.redact(normalizedBody)
            let truncatedBody = redactedBody.count > 200
                ? String(redactedBody.prefix(200)) + "…"
                : redactedBody
            return "OpenAI request failed with HTTP \(statusCode): \(truncatedBody)"
        case .playbackFailed(let message):
            return message
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
