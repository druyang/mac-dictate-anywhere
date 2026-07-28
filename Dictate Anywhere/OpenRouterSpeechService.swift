//
//  OpenRouterSpeechService.swift
//  Dictate Anywhere
//
//  OpenRouter speech-model discovery and text-to-speech synthesis.
//

import Foundation

enum OpenRouterSpeechService {
    private static let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    private static let appAttributionURL = "https://github.com/hoomanaskari/mac-dictate-anywhere"
    private static let appTitle = "Dictate Anywhere"
    private static let maximumSynthesisAttempts = 2

    typealias SpeechDataLoader =
        @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias RetrySleeper =
        @Sendable (TimeInterval) async throws -> Void

    struct Model: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let description: String
        let supportedVoices: [String]
        let pricePerCharacter: String?

        var displayName: String {
            name.isEmpty ? id : name
        }

        var priceSummary: String? {
            guard let pricePerCharacter,
                  let price = Double(pricePerCharacter),
                  price > 0 else {
                return nil
            }
            return String(format: "$%.2f / 1M characters", price * 1_000_000)
        }
    }

    enum ServiceError: LocalizedError {
        case missingModel
        case missingVoice
        case invalidResponse
        case emptyResponse
        case rateLimited(retryAfterSeconds: Int?)
        case serverMessage(String)
        case unexpectedStatus(Int)

        var errorDescription: String? {
            switch self {
            case .missingModel:
                return "Choose an OpenRouter speech model."
            case .missingVoice:
                return "Choose or enter a voice for the selected OpenRouter speech model."
            case .invalidResponse:
                return "OpenRouter returned an invalid speech response."
            case .emptyResponse:
                return "OpenRouter returned empty speech audio."
            case .rateLimited(let retryAfterSeconds):
                if let retryAfterSeconds {
                    return "The speech provider is rate-limited. Try again in \(retryAfterSeconds) seconds or choose another speech model."
                }
                return "The speech provider is temporarily rate-limited. Wait a moment and try again, or choose another speech model."
            case .serverMessage(let message):
                return message
            case .unexpectedStatus(let status):
                return "OpenRouter speech returned HTTP \(status)."
            }
        }
    }

    static func fetchModels() async throws -> [Model] {
        var components = URLComponents(
            url: baseURL.appending(path: "models"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "output_modalities", value: "speech")
        ]
        guard let url = components?.url else {
            throw ServiceError.invalidResponse
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decodeModels(from: data)
    }

    static func synthesize(
        text: String,
        model: String,
        voice: String,
        apiKey: String,
        apiKeyEnvironmentVariable: String,
        dataLoader: @escaping SpeechDataLoader = {
            try await URLSession.shared.data(for: $0)
        },
        sleep: @escaping RetrySleeper = {
            try await Task.sleep(for: .seconds($0))
        }
    ) async throws -> Data {
        try Task.checkCancellation()
        let resolvedKey = try OpenRouterPostProcessingService.resolvedAPIKey(
            apiKey: apiKey,
            apiKeyEnvironmentVariable: apiKeyEnvironmentVariable
        )
        let request = try makeSpeechRequest(
            text: text,
            model: model,
            voice: voice,
            apiKey: resolvedKey
        )

        for attempt in 0..<maximumSynthesisAttempts {
            try Task.checkCancellation()
            let (data, response) = try await dataLoader(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.invalidResponse
            }

            if shouldRetry(status: httpResponse.statusCode),
               attempt + 1 < maximumSynthesisAttempts {
                let delay = retryDelay(
                    retryAfterHeader:
                        httpResponse.value(forHTTPHeaderField: "Retry-After")
                )
                try await sleep(delay)
                continue
            }

            try validate(response: httpResponse, data: data)
            guard !data.isEmpty else {
                throw ServiceError.emptyResponse
            }
            return data
        }

        throw ServiceError.invalidResponse
    }

    static func retryDelay(
        retryAfterHeader: String?
    ) -> TimeInterval {
        if let retryAfterHeader,
           let serverDelay = TimeInterval(
               retryAfterHeader.trimmingCharacters(in: .whitespacesAndNewlines)
           ),
           serverDelay > 0 {
            return serverDelay
        }
        return 2
    }

    static func makeSpeechRequest(
        text: String,
        model: String,
        voice: String,
        apiKey: String
    ) throws -> URLRequest {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ServiceError.missingModel
        }
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoice.isEmpty else {
            throw ServiceError.missingVoice
        }

        var request = URLRequest(url: baseURL.appending(path: "audio/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(appAttributionURL, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(appTitle, forHTTPHeaderField: "X-OpenRouter-Title")
        request.setValue(appTitle, forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": trimmedModel,
                "input": text,
                "voice": trimmedVoice,
                "response_format": "mp3",
            ]
        )
        return request
    }

    static func decodeModels(from data: Data) throws -> [Model] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        var seen = Set<String>()
        return decoded.data.compactMap { model in
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else {
                return nil
            }
            return Model(
                id: id,
                name: model.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                description: model.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                supportedVoices: (model.supportedVoices ?? []).filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                },
                pricePerCharacter: model.pricing?.prompt
            )
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func matchingModel(for selectedModel: String, in models: [Model]) -> Model? {
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.first {
            $0.id.caseInsensitiveCompare(trimmedModel) == .orderedSame
        }
    }

    static func isConfigured(
        model: String,
        voice: String,
        apiKey: String,
        apiKeyEnvironmentVariable: String
    ) -> Bool {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return OpenRouterPostProcessingService.apiKeyStatus(
            apiKey: apiKey,
            apiKeyEnvironmentVariable: apiKeyEnvironmentVariable
        ).isConfigured
    }

    private struct ModelsResponse: Decodable {
        let data: [ModelResponse]
    }

    private struct ModelResponse: Decodable {
        struct PricingResponse: Decodable {
            let prompt: String?
        }

        let id: String
        let name: String?
        let description: String?
        let supportedVoices: [String]?
        let pricing: PricingResponse?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case description
            case supportedVoices = "supported_voices"
            case pricing
        }
    }

    private struct ErrorResponse: Decodable {
        struct ErrorPayload: Decodable {
            let message: String?
        }

        let error: ErrorPayload?
        let message: String?
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 {
                let retryAfterSeconds = httpResponse
                    .value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                    .map { Int($0.rounded(.up)) }
                throw ServiceError.rateLimited(
                    retryAfterSeconds: retryAfterSeconds
                )
            }
            if let apiError = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                let message = apiError.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? apiError.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
                if !message.isEmpty {
                    throw ServiceError.serverMessage(message)
                }
            }
            throw ServiceError.unexpectedStatus(httpResponse.statusCode)
        }
    }

    private static func shouldRetry(status: Int) -> Bool {
        status == 429 || status == 503
    }
}
