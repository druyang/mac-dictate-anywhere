//
//  VoiceAgentService.swift
//  Dictate Anywhere
//
//  Provider-neutral question answering and local spoken-response playback.
//

import Foundation
import FoundationModels

enum VoiceAgentInstructions {
    private static let legacyResponseLengthRestriction =
        "Keep the response concise: normally one to three short sentences and no more than 80 words."

    static let system = """
    You are the voice assistant inside Dictate Anywhere.
    Answer the user's request directly and conversationally.
    Your response will be spoken aloud, so use plain text with no Markdown, headings, bullets, citations, or raw URLs.
    Match the level of detail to the user's request and provide a complete answer.
    If the request cannot be completed without tools you do not have, say what information is missing instead of pretending it was completed.
    """

    static func migratingLegacyPrompt(_ prompt: String) -> String {
        prompt
            .components(separatedBy: .newlines)
            .filter {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    != legacyResponseLengthRestriction
            }
            .joined(separator: "\n")
    }
}

enum VoiceAgentToolCatalog {
    static let codexDirective = "[[tool:codex_project]]"

    static func brainInstructions(
        systemPrompt: String,
        codexEnabled: Bool,
        webSearchEnabled: Bool = false
    ) -> String {
        var capabilityInstructions: [String] = []

        if webSearchEnabled {
            capabilityInstructions.append(
                """
                OPENROUTER WEB SEARCH
                You have working web access through the openrouter:web_search tool.
                Use it when the user asks you to search, browse, look up, or verify something online, or when current, recent, or latest information is needed.
                If the user asks whether you have web access, answer yes.
                Do not claim that browsing is unavailable while this capability is enabled.
                """
            )
        }

        if codexEnabled {
            capabilityInstructions.append(
                """
                AVAILABLE TOOL
                codex_project: Read-only access to the selected local project. It can inspect files, source code, git status and history, branches, dependencies, configuration, tests, build setup, and other repository-specific facts. It cannot modify files or access the web.

                If answering the request requires inspecting the selected local project, respond with exactly \(codexDirective) and nothing else. Do not ask the user to mention Codex by name. Do not use this tool for general knowledge or web searches.
                """
            )
        }

        guard !capabilityInstructions.isEmpty else { return systemPrompt }
        return ([systemPrompt] + capabilityInstructions).joined(separator: "\n\n")
    }

    static func isCodexRequest(_ response: String) -> Bool {
        Self.normalized(response) == Self.normalized(codexDirective)
    }

    static func couldBeCodexRequest(_ response: String) -> Bool {
        let candidate = normalized(response)
        return !candidate.isEmpty
            && normalized(codexDirective).hasPrefix(candidate)
    }

    private static func normalized(_ response: String) -> String {
        response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

actor VoiceAgentToolStartGate {
    private var isReleased = false

    func wait() async throws {
        while !isReleased {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func release() {
        isReleased = true
    }
}

struct VoiceAgentToolStatus: Sendable {
    let message: String
    private let startGate: VoiceAgentToolStartGate

    init(message: String, startGate: VoiceAgentToolStartGate) {
        self.message = message
        self.startGate = startGate
    }

    func didFinishSpeaking() async {
        await startGate.release()
    }
}

enum VoiceAgentStreamEvent: Sendable {
    case toolStatus(VoiceAgentToolStatus)
    case response(String)
}

enum VoiceAgentToolAcknowledgement {
    static func message(
        for userRequest: String,
        variantIndex: Int? = nil
    ) -> String {
        let request = userRequest.lowercased()
        let variants: [String]

        if ["git", "gift status", "branch", "commit", "uncommitted", "diff"]
            .contains(where: request.contains) {
            variants = [
                "I’ll check the project’s git state with Codex. This may take a moment.",
                "Let me have Codex inspect the repository status. This could take a little while.",
                "I’ll use Codex to review the current git changes. Give me a moment.",
            ]
        } else if ["file", "folder", "code", "source", "test", "build", "dependency", "config"]
            .contains(where: request.contains) {
            variants = [
                "I’ll have Codex inspect the relevant project files. This may take a moment.",
                "Let me check the codebase with Codex. This could take a little while.",
                "I’ll ask Codex to review the project details. Give me a moment.",
            ]
        } else {
            variants = [
                "I’ll check the selected project with Codex. This may take a moment.",
                "Let me inspect the project with Codex. This could take a little while.",
                "I’ll ask Codex to look into that project request. Give me a moment.",
            ]
        }

        let index = variantIndex ?? Int.random(in: variants.indices)
        return variants[index.modulo(variants.count)]
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

enum VoiceAgentService {
    struct Configuration: Sendable {
        let provider: AgentBrainProvider
        let systemPrompt: String
        let ollamaBaseURL: String
        let ollamaModel: String
        let ollamaReasoning: OllamaReasoningSetting
        let openRouterModel: String
        let openRouterWebSearchEnabled: Bool
        let openRouterAPIKey: String
        let openRouterAPIKeyEnvironmentVariable: String
        let codexToolEnabled: Bool
        let codexWorkspacePath: String

        init(settings: Settings) {
            provider = settings.agentBrainProvider
            systemPrompt = settings.agentSystemPrompt
            ollamaBaseURL = settings.ollamaBaseURL
            ollamaModel = settings.ollamaModel
            ollamaReasoning = settings.ollamaReasoningSetting
            openRouterModel = settings.openRouterModel
            openRouterWebSearchEnabled = settings.agentOpenRouterWebSearchEnabled
            openRouterAPIKey = settings.openRouterAPIKey
            openRouterAPIKeyEnvironmentVariable = settings.openRouterAPIKeyEnvironmentVariable
            codexToolEnabled = settings.codexToolEnabled
            codexWorkspacePath = settings.codexWorkspacePath
        }
    }

    enum ServiceError: LocalizedError {
        case appleIntelligenceRequiresMacOS26
        case appleIntelligenceUnavailable
        case emptyPrompt
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .appleIntelligenceRequiresMacOS26:
                return "Apple Intelligence responses require macOS 26 or later."
            case .appleIntelligenceUnavailable:
                return "Apple Intelligence is not available. Enable it in System Settings or choose another assistant brain."
            case .emptyPrompt:
                return "Nothing was transcribed. Try asking again."
            case .emptyResponse:
                return "The selected assistant brain returned an empty response."
            }
        }
    }

    static func respond(to prompt: String, configuration: Configuration) async throws -> String {
        var response = ""
        for try await partialResponse in streamResponse(to: prompt, configuration: configuration) {
            response = partialResponse
        }
        return response
    }

    static func streamResponse(
        to prompt: String,
        configuration: Configuration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in streamEvents(to: prompt, configuration: configuration) {
                        switch event {
                        case .toolStatus(let status):
                            await status.didFinishSpeaking()
                        case .response(let response):
                            continuation.yield(response)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func streamEvents(
        to prompt: String,
        configuration: Configuration
    ) -> AsyncThrowingStream<VoiceAgentStreamEvent, Error> {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !trimmedPrompt.isEmpty else {
                        throw ServiceError.emptyPrompt
                    }

                    var finalResponse = ""
                    if CodexToolIntent.matches(trimmedPrompt) {
                        guard configuration.codexToolEnabled else {
                            throw CodexToolService.ServiceError.disabled
                        }
                        try await yieldCodexAcknowledgement(
                            for: trimmedPrompt,
                            continuation: continuation
                        )
                        try Task.checkCancellation()
                        let source = CodexToolService.streamResponse(
                            to: trimmedPrompt,
                            workspacePath: configuration.codexWorkspacePath,
                            systemPrompt: configuration.systemPrompt
                        )
                        try await yieldResponses(
                            from: source,
                            continuation: continuation,
                            finalResponse: &finalResponse
                        )
                    } else {
                        let brainInstructions = VoiceAgentToolCatalog.brainInstructions(
                            systemPrompt: configuration.systemPrompt,
                            codexEnabled: configuration.codexToolEnabled,
                            webSearchEnabled: configuration.provider == .openRouter
                                && configuration.openRouterWebSearchEnabled
                        )
                        let source = brainResponseStream(
                            to: trimmedPrompt,
                            systemPrompt: brainInstructions,
                            configuration: configuration
                        )

                        var bufferedResponse = ""
                        var emittedBrainResponse = false
                        for try await rawResponse in source {
                            try Task.checkCancellation()
                            let response = SpokenResponseFormatter.plainText(from: rawResponse)
                            guard !response.isEmpty else { continue }

                            if !emittedBrainResponse,
                               VoiceAgentToolCatalog.couldBeCodexRequest(response) {
                                bufferedResponse = response
                                continue
                            }

                            emittedBrainResponse = true
                            guard response != finalResponse else { continue }
                            finalResponse = response
                            continuation.yield(.response(response))
                        }

                        if VoiceAgentToolCatalog.isCodexRequest(bufferedResponse) {
                            try await yieldCodexAcknowledgement(
                                for: trimmedPrompt,
                                continuation: continuation
                            )
                            try Task.checkCancellation()
                            let codexSource = CodexToolService.streamResponse(
                                to: trimmedPrompt,
                                workspacePath: configuration.codexWorkspacePath,
                                systemPrompt: configuration.systemPrompt
                            )
                            try await yieldResponses(
                                from: codexSource,
                                continuation: continuation,
                                finalResponse: &finalResponse
                            )
                        } else if !emittedBrainResponse, !bufferedResponse.isEmpty {
                            finalResponse = bufferedResponse
                            continuation.yield(.response(bufferedResponse))
                        }
                    }

                    guard !finalResponse.isEmpty else {
                        throw ServiceError.emptyResponse
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func yieldResponses(
        from source: AsyncThrowingStream<String, Error>,
        continuation: AsyncThrowingStream<VoiceAgentStreamEvent, Error>.Continuation,
        finalResponse: inout String
    ) async throws {
        for try await rawResponse in source {
            try Task.checkCancellation()
            let response = SpokenResponseFormatter.plainText(from: rawResponse)
            guard !response.isEmpty, response != finalResponse else { continue }
            finalResponse = response
            continuation.yield(.response(response))
        }
    }

    private static func yieldCodexAcknowledgement(
        for prompt: String,
        continuation: AsyncThrowingStream<VoiceAgentStreamEvent, Error>.Continuation
    ) async throws {
        let startGate = VoiceAgentToolStartGate()
        continuation.yield(
            .toolStatus(
                VoiceAgentToolStatus(
                    message: VoiceAgentToolAcknowledgement.message(for: prompt),
                    startGate: startGate
                )
            )
        )
        try await startGate.wait()
    }

    private static func brainResponseStream(
        to prompt: String,
        systemPrompt: String,
        configuration: Configuration
    ) -> AsyncThrowingStream<String, Error> {
        switch configuration.provider {
        case .appleIntelligence:
            return appleIntelligenceResponseStream(
                to: prompt,
                systemPrompt: systemPrompt
            )
        case .ollama:
            return OllamaPostProcessingService.streamAnswer(
                text: prompt,
                baseURL: configuration.ollamaBaseURL,
                model: configuration.ollamaModel,
                reasoning: configuration.ollamaReasoning,
                instructions: systemPrompt
            )
        case .openRouter:
            return OpenRouterPostProcessingService.streamAnswer(
                text: prompt,
                model: configuration.openRouterModel,
                instructions: systemPrompt,
                webSearchEnabled: configuration.openRouterWebSearchEnabled,
                apiKey: configuration.openRouterAPIKey,
                apiKeyEnvironmentVariable: configuration.openRouterAPIKeyEnvironmentVariable
            )
        }
    }

    private static func appleIntelligenceResponseStream(
        to prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard #available(macOS 26, *) else {
                        throw ServiceError.appleIntelligenceRequiresMacOS26
                    }
                    guard case .available = SystemLanguageModel.default.availability else {
                        throw ServiceError.appleIntelligenceUnavailable
                    }

                    let session = LanguageModelSession(instructions: systemPrompt)
                    for try await snapshot in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

enum SpokenResponseFormatter {
    private static let maximumSpokenErrorCharacters = 320

    static func plainText(from response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        text = text.replacingOccurrences(
            of: #"```(?:[A-Za-z0-9_+-]+)?\s*([\s\S]*?)```"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?m)^\s{0,3}(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)"#,
            with: "",
            options: .regularExpression
        )
        text = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func errorText(from message: String) -> String {
        var text = plainText(from: message)
        guard !text.isEmpty else {
            return "Sorry. Something went wrong."
        }

        if text.count > maximumSpokenErrorCharacters {
            let prefix = String(text.prefix(maximumSpokenErrorCharacters))
            if let finalSpace = prefix.lastIndex(of: " ") {
                text = String(prefix[..<finalSpace])
            } else {
                text = prefix
            }
            text = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                + "."
        }

        if text.lowercased().hasPrefix("sorry") {
            return text
        }
        return "Sorry. \(text)"
    }
}
