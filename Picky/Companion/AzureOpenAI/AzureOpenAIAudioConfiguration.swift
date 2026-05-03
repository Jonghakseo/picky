//
//  AzureOpenAIAudioConfiguration.swift
//  Picky
//
//  Shared configuration for Azure OpenAI audio providers. Default factories can
//  select these providers when PICKY_STT_PROVIDER/PICKY_TTS_PROVIDER is set.
//

import Foundation

struct AzureOpenAIAudioConfiguration: Equatable {
    var endpoint: URL?
    var apiKey: String?
    var deploymentName: String?
    var apiVersion: String
    var requestTimeout: TimeInterval

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
