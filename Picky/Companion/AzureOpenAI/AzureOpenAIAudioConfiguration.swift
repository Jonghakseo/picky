//
//  AzureOpenAIAudioConfiguration.swift
//  Picky
//
//  Shared configuration for Azure OpenAI audio providers. STT settings can be
//  derived from the full audio/transcriptions URL copied from the Azure portal.
//

import Foundation

struct AzureOpenAIAudioConfiguration: Equatable {
    var endpoint: URL?
    var apiKey: String?
    var deploymentName: String?
    var apiVersion: String
    var requestTimeout: TimeInterval

    private struct ParsedAudioEndpoint: Equatable {
        let endpoint: URL
        let deploymentName: String
        let apiVersion: String?
    }

    init(
        endpoint: URL?,
        apiKey: String?,
        deploymentName: String?,
        apiVersion: String,
        requestTimeout: TimeInterval = 30
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.deploymentName = deploymentName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.apiVersion = apiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestTimeout = requestTimeout
    }

    var isConfigured: Bool {
        endpoint != nil
            && apiKey != nil
            && deploymentName != nil
            && !apiVersion.isEmpty
    }

    var missingConfigurationExplanation: String? {
        guard !isConfigured else { return nil }

        var missing = [String]()
        if endpoint == nil { missing.append("endpoint") }
        if apiKey == nil { missing.append("api key") }
        if deploymentName == nil { missing.append("deployment name") }
        if apiVersion.isEmpty { missing.append("api version") }

        return "Azure OpenAI audio provider is missing: \(missing.joined(separator: ", "))."
    }

    static func fromTranscriptionEndpointURL(
        _ endpointURLString: String?,
        apiKey: String?,
        requestTimeout: TimeInterval = 30
    ) -> AzureOpenAIAudioConfiguration {
        fromAudioEndpointURL(
            endpointURLString,
            apiKey: apiKey,
            expectedAudioPath: ["audio", "transcriptions"],
            fallbackDeploymentName: nil,
            defaultAPIVersion: nil,
            requestTimeout: requestTimeout
        )
    }

    static func fromSpeechEndpointURL(
        _ endpointURLString: String?,
        apiKey: String?,
        fallbackDeploymentName: String? = nil,
        defaultAPIVersion: String,
        requestTimeout: TimeInterval = 30
    ) -> AzureOpenAIAudioConfiguration {
        fromAudioEndpointURL(
            endpointURLString,
            apiKey: apiKey,
            expectedAudioPath: ["audio", "speech"],
            fallbackDeploymentName: fallbackDeploymentName,
            defaultAPIVersion: defaultAPIVersion,
            requestTimeout: requestTimeout
        )
    }

    private static func fromAudioEndpointURL(
        _ endpointURLString: String?,
        apiKey: String?,
        expectedAudioPath: [String],
        fallbackDeploymentName: String?,
        defaultAPIVersion: String?,
        requestTimeout: TimeInterval
    ) -> AzureOpenAIAudioConfiguration {
        let trimmedEndpoint = endpointURLString?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let parsedEndpoint = trimmedEndpoint.flatMap { parseAudioEndpointURL($0, expectedAudioPath: expectedAudioPath) }

        return AzureOpenAIAudioConfiguration(
            endpoint: parsedEndpoint?.endpoint ?? trimmedEndpoint.flatMap { sanitizedURL(from: $0) },
            apiKey: apiKey,
            deploymentName: parsedEndpoint?.deploymentName ?? fallbackDeploymentName,
            apiVersion: parsedEndpoint?.apiVersion ?? defaultAPIVersion ?? "",
            requestTimeout: requestTimeout
        )
    }

    private static func parseAudioEndpointURL(_ rawURLString: String, expectedAudioPath: [String]) -> ParsedAudioEndpoint? {
        guard var components = URLComponents(string: rawURLString),
              components.scheme != nil,
              components.host != nil else { return nil }

        let pathParts = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard let openAIIndex = pathParts.firstIndex(where: { $0.caseInsensitiveCompare("openai") == .orderedSame }),
              pathParts.indices.contains(openAIIndex + 2),
              pathParts[openAIIndex + 1].caseInsensitiveCompare("deployments") == .orderedSame else {
            return nil
        }

        let encodedDeploymentName = pathParts[openAIIndex + 2]
        guard let deploymentName = (encodedDeploymentName.removingPercentEncoding ?? encodedDeploymentName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return nil
        }

        let remainingPath = pathParts.dropFirst(openAIIndex + 3).map { $0.lowercased() }
        let normalizedExpectedAudioPath = expectedAudioPath.map { $0.lowercased() }
        guard remainingPath.count >= normalizedExpectedAudioPath.count,
              Array(remainingPath.prefix(normalizedExpectedAudioPath.count)) == normalizedExpectedAudioPath else {
            return nil
        }

        let apiVersion = components.queryItems?
            .first { $0.name.caseInsensitiveCompare("api-version") == .orderedSame }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let basePathParts = pathParts.prefix(openAIIndex)
        components.percentEncodedPath = basePathParts.isEmpty ? "" : "/\(basePathParts.joined(separator: "/"))"
        components.queryItems = nil
        components.fragment = nil

        guard let endpoint = components.url else { return nil }
        return ParsedAudioEndpoint(
            endpoint: endpoint,
            deploymentName: deploymentName,
            apiVersion: apiVersion
        )
    }

    private static func sanitizedURL(from rawURLString: String) -> URL? {
        guard var components = URLComponents(string: rawURLString),
              components.scheme != nil,
              components.host != nil else { return nil }
        components.queryItems = nil
        components.fragment = nil
        return components.url
    }

    static func fromEnvironment(
        deploymentEnvironmentKey: String,
        defaultAPIVersion: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AzureOpenAIAudioConfiguration {
        let endpointString = AzureOpenAIKeychainStore.value(
            for: "AZURE_OPENAI_ENDPOINT",
            environment: environment
        )
        let endpoint = endpointString.flatMap(URL.init(string:))

        return AzureOpenAIAudioConfiguration(
            endpoint: endpoint,
            apiKey: AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_API_KEY", environment: environment),
            deploymentName: AzureOpenAIKeychainStore.value(for: deploymentEnvironmentKey, environment: environment)
                ?? AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_DEPLOYMENT_NAME", environment: environment),
            apiVersion: AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_API_VERSION", environment: environment)
                ?? AzureOpenAIKeychainStore.value(for: "OPENAI_API_VERSION", environment: environment)
                ?? defaultAPIVersion
        )
    }

    func deploymentURL(forAudioPath audioPath: String) -> URL? {
        guard let endpoint,
              let deploymentName,
              !apiVersion.isEmpty else { return nil }

        let normalizedEndpoint = endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedDeploymentName = deploymentName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deploymentName
        let normalizedAudioPath = audioPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedAPIVersion = apiVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiVersion

        return URL(string: "\(normalizedEndpoint)/openai/deployments/\(encodedDeploymentName)/\(normalizedAudioPath)?api-version=\(encodedAPIVersion)")
    }

    func configuredAPIKey() throws -> String {
        guard let apiKey else {
            throw AzureOpenAIAudioProviderError.notConfigured(missingConfigurationExplanation ?? "Azure OpenAI API key is missing.")
        }
        return apiKey
    }
}

enum AzureOpenAIAudioProviderError: LocalizedError {
    case notConfigured(String)
    case invalidEndpoint(String)
    case noAudioCaptured
    case emptyResponse
    case httpError(statusCode: Int, body: String)
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message):
            return message
        case .invalidEndpoint(let path):
            return "Invalid Azure OpenAI audio endpoint for path: \(path)."
        case .noAudioCaptured:
            return "No audio was captured for Azure OpenAI transcription."
        case .emptyResponse:
            return "Azure OpenAI returned an empty audio response."
        case .httpError(let statusCode, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else {
                return "Azure OpenAI request failed with HTTP \(statusCode)."
            }
            return "Azure OpenAI request failed with HTTP \(statusCode): \(trimmedBody)"
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
