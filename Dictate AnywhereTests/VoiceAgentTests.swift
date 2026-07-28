import AVFoundation
import FluidAudio
import FoundationModels
import XCTest
@testable import Dictate_Anywhere_Dev

private actor VoiceAgentTestFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private actor OpenRouterSpeechRetryTestHarness {
    private let successOnRequest: Int?
    private(set) var requestCount = 0
    private(set) var sleepDelays: [TimeInterval] = []

    init(successOnRequest: Int? = 2) {
        self.successOnRequest = successOnRequest
    }

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestCount += 1
        let succeeded = requestCount == successOnRequest
        let status = succeeded ? 200 : 429
        let headers = succeeded ? [:] : ["Retry-After": "3"]
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: "HTTP/2",
                headerFields: headers
            )
        )
        let data = succeeded
            ? Data([0x01, 0x02, 0x03])
            : Data(#"{"error":{"message":"Provider returned 429"}}"#.utf8)
        return (data, response)
    }

    func recordSleep(_ delay: TimeInterval) {
        sleepDelays.append(delay)
    }
}

final class VoiceAgentTests: XCTestCase {
    private func conversationExchange(
        user: String = "What is my favorite editor?",
        assistant: String = "Your favorite editor is Xcode."
    ) -> VoiceConversationExchange {
        VoiceConversationExchange(
            id: UUID(),
            userMessage: user,
            assistantMessage: assistant,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            provider: .appleIntelligence,
            model: "system-language-model"
        )
    }

    func testCodexIntentRequiresWholeWordMention() {
        XCTAssertTrue(CodexToolIntent.matches("Ask Codex what this project does."))
        XCTAssertTrue(CodexToolIntent.matches("Can you check this with codex?"))
        XCTAssertFalse(CodexToolIntent.matches("What should I focus on today?"))
        XCTAssertFalse(CodexToolIntent.matches("My codexification experiment"))
    }

    func testCodexIntentRecognizesImplicitProjectInspection() {
        XCTAssertTrue(
            CodexToolIntent.matches("Can you check the git status of the current project?")
        )
        XCTAssertTrue(
            CodexToolIntent.matches("Which files have uncommitted changes?")
        )
        XCTAssertTrue(
            CodexToolIntent.matches("Explain the package dependencies in this repository.")
        )
        XCTAssertTrue(
            CodexToolIntent.matches("Read Package.swift and summarize the targets.")
        )
    }

    func testCodexIntentLeavesWebAndGeneralQuestionsWithAssistantBrain() {
        XCTAssertFalse(
            CodexToolIntent.matches("Search the web for the latest Swift release.")
        )
        XCTAssertFalse(
            CodexToolIntent.matches("What is a good way to organize a personal project?")
        )
        XCTAssertFalse(
            CodexToolIntent.matches("Explain what source control is.")
        )
    }

    func testToolCatalogCanRequestCodexWithoutShowingDirectiveToUser() {
        let instructions = VoiceAgentToolCatalog.brainInstructions(
            systemPrompt: "Keep answers short.",
            codexEnabled: true,
            webSearchEnabled: false
        )

        XCTAssertTrue(instructions.contains("codex_project"))
        XCTAssertTrue(instructions.contains("git status"))
        XCTAssertTrue(
            VoiceAgentToolCatalog.isCodexRequest(
                VoiceAgentToolCatalog.codexDirective
            )
        )
        XCTAssertTrue(VoiceAgentToolCatalog.couldBeCodexRequest("[[tool:codex"))
        XCTAssertFalse(VoiceAgentToolCatalog.isCodexRequest("I can answer directly."))
    }

    func testToolCatalogMakesEnabledWebAccessExplicitToAssistant() {
        let instructions = VoiceAgentToolCatalog.brainInstructions(
            systemPrompt: "Keep answers short.",
            codexEnabled: false,
            webSearchEnabled: true
        )

        XCTAssertTrue(instructions.contains("openrouter:web_search"))
        XCTAssertTrue(instructions.contains("If the user asks whether you have web access, answer yes."))
        XCTAssertTrue(instructions.contains("current, recent, or latest information"))
        XCTAssertFalse(instructions.contains("codex_project"))
    }

    func testToolCatalogDoesNotClaimWebAccessWhenDisabled() {
        let instructions = VoiceAgentToolCatalog.brainInstructions(
            systemPrompt: "Keep answers short.",
            codexEnabled: false,
            webSearchEnabled: false
        )

        XCTAssertEqual(instructions, "Keep answers short.")
        XCTAssertFalse(instructions.contains("openrouter:web_search"))
    }

    func testToolAcknowledgementIsImmediateContextualAndVaried() {
        let first = VoiceAgentToolAcknowledgement.message(
            for: "Check the git status of this project.",
            variantIndex: 0
        )
        let second = VoiceAgentToolAcknowledgement.message(
            for: "Check the git status of this project.",
            variantIndex: 1
        )

        XCTAssertTrue(first.contains("git state"))
        XCTAssertTrue(first.contains("Codex"))
        XCTAssertTrue(first.contains("may take a moment"))
        XCTAssertNotEqual(first, second)
    }

    func testToolAcknowledgementDescribesFileInspection() {
        XCTAssertEqual(
            VoiceAgentToolAcknowledgement.message(
                for: "Review the changed Swift files.",
                variantIndex: 0
            ),
            "I’ll have Codex inspect the relevant project files. This may take a moment."
        )
    }

    func testToolStartGateWaitsForSpokenAcknowledgement() async throws {
        let gate = VoiceAgentToolStartGate()
        let didStart = VoiceAgentTestFlag()
        let task = Task {
            try await gate.wait()
            await didStart.set()
        }

        try await Task.sleep(for: .milliseconds(60))
        let startedBeforeAcknowledgementFinished = await didStart.value
        XCTAssertFalse(startedBeforeAcknowledgementFinished)

        await gate.release()
        try await task.value
        let startedAfterAcknowledgementFinished = await didStart.value
        XCTAssertTrue(startedAfterAcknowledgementFinished)
    }

    func testCodexArgumentsEnforceReadOnlyEphemeralExecution() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let arguments = try CodexToolService.commandArguments(workspacePath: workspace.path)

        XCTAssertEqual(arguments.first, "exec")
        XCTAssertEqual(arguments.last, "-")
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("--ignore-rules"))
        XCTAssertTrue(arguments.contains(#"approval_policy="never""#))
        XCTAssertTrue(arguments.contains(#"default_permissions="dictate_readonly""#))
        XCTAssertTrue(arguments.contains("permissions.dictate_readonly.network.enabled=false"))
        XCTAssertTrue(arguments.contains(#"web_search="disabled""#))
        XCTAssertTrue(arguments.contains(workspace.path))
        XCTAssertFalse(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testCodexWorkspaceRejectsBroadOrNonGitFolders() {
        XCTAssertNotNil(
            CodexToolService.workspaceValidationError(
                FileManager.default.homeDirectoryForCurrentUser.path
            )
        )
        XCTAssertNotNil(
            CodexToolService.workspaceValidationError(
                FileManager.default.temporaryDirectory.path
            )
        )
    }

    func testSpokenResponseFormatterRemovesCommonMarkdown() {
        let response = """
        ## Result
        - **First** useful thing
        - `Second` useful thing
        """

        XCTAssertEqual(
            SpokenResponseFormatter.plainText(from: response),
            "Result First useful thing Second useful thing"
        )
    }

    func testSpokenResponseFormatterUnwrapsCodeFence() {
        let response = """
        ```text
        The answer is forty-two.
        ```
        """

        XCTAssertEqual(
            SpokenResponseFormatter.plainText(from: response),
            "The answer is forty-two."
        )
    }

    func testSpokenResponseFormatterCollapsesWhitespace() {
        XCTAssertEqual(
            SpokenResponseFormatter.plainText(from: "  One\n\n two   three.  "),
            "One two three."
        )
    }

    func testSpokenResponseFormatterMakesErrorsNaturalToSpeak() {
        XCTAssertEqual(
            SpokenResponseFormatter.errorText(
                from: "Codex access is turned off. Enable it in Voice Assistant settings."
            ),
            "Sorry. Codex access is turned off. Enable it in Voice Assistant settings."
        )
        XCTAssertEqual(
            SpokenResponseFormatter.errorText(from: ""),
            "Sorry. Something went wrong."
        )
        XCTAssertEqual(
            SpokenResponseFormatter.errorText(from: "Sorry, the request failed."),
            "Sorry, the request failed."
        )
    }

    func testSpokenResponseFormatterLimitsLongErrors() {
        let spoken = SpokenResponseFormatter.errorText(
            from: String(repeating: "technical failure ", count: 100)
        )

        XCTAssertLessThanOrEqual(spoken.count, 328)
        XCTAssertTrue(spoken.hasPrefix("Sorry. "))
        XCTAssertTrue(spoken.hasSuffix("."))
    }

    @MainActor
    func testSpokenResponseFormatterSupportsCumulativeStreamingSnapshots() {
        let snapshots = [
            "A useful",
            "A useful thing",
            "A useful thing to focus on.",
        ]

        XCTAssertEqual(
            snapshots.map(SpokenResponseFormatter.plainText),
            snapshots
        )
    }

    func testVoiceAgentPromptIsDesignedForSpeechWithoutRestrictingAnswerLength() {
        let instructions = VoiceAgentInstructions.system
        XCTAssertTrue(instructions.contains("spoken aloud"))
        XCTAssertTrue(instructions.contains("no Markdown"))
        XCTAssertTrue(instructions.contains("provide a complete answer"))
        XCTAssertFalse(instructions.contains("80 words"))
        XCTAssertFalse(instructions.contains("one to three short sentences"))
    }

    func testVoiceAgentMigratesLegacyLengthRestrictionWithoutDroppingCustomInstructions() {
        let prompt = """
        You are the voice assistant inside Dictate Anywhere.
        Keep the response concise: normally one to three short sentences and no more than 80 words.
        DO NOT RETURN URLS or LINKS IN YOUR RESPONSES
        """

        let migrated = VoiceAgentInstructions.migratingLegacyPrompt(prompt)

        XCTAssertFalse(migrated.contains("80 words"))
        XCTAssertFalse(migrated.contains("one to three short sentences"))
        XCTAssertTrue(migrated.contains("You are the voice assistant inside Dictate Anywhere."))
        XCTAssertTrue(migrated.contains("DO NOT RETURN URLS or LINKS IN YOUR RESPONSES"))
    }

    func testOpenRouterWebAccessUsesServerToolAndMigratesOnlineSuffix() throws {
        let request = try OpenRouterPostProcessingService.makeStreamingAnswerRequest(
            text: "What changed in Swift today?",
            model: "openai/gpt-5-mini:online",
            instructions: "Answer clearly.",
            webSearchEnabled: true,
            apiKey: "sk-or-test"
        )

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(payload["model"] as? String, "openai/gpt-5-mini")
        XCTAssertEqual(payload["max_tool_calls"] as? Int, 3)
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "openrouter:web_search")
    }

    func testOpenRouterWebAccessOffDoesNotExposeSearchTool() throws {
        let request = try OpenRouterPostProcessingService.makeStreamingAnswerRequest(
            text: "Explain Swift actors.",
            model: "openai/gpt-5-mini:online",
            instructions: "Answer clearly.",
            webSearchEnabled: false,
            apiKey: "sk-or-test"
        )

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(payload["model"] as? String, "openai/gpt-5-mini")
        XCTAssertNil(payload["tools"])
        XCTAssertNil(payload["max_tool_calls"])
    }

    func testOpenRouterConversationHistoryUsesAlternatingMessageRoles() throws {
        let history = VoiceConversationContext.messages(from: [conversationExchange()])
        let request = try OpenRouterPostProcessingService.makeStreamingAnswerRequest(
            text: "What about my IDE?",
            model: "openai/gpt-5-mini",
            instructions: "Answer clearly.",
            history: history,
            webSearchEnabled: false,
            apiKey: "sk-or-test"
        )

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, [
            "system",
            "user",
            "assistant",
            "user",
        ])
        XCTAssertEqual(messages[1]["content"], "What is my favorite editor?")
        XCTAssertEqual(messages[2]["content"], "Your favorite editor is Xcode.")
        XCTAssertEqual(messages[3]["content"], "What about my IDE?")
    }

    func testOllamaConversationHistoryUsesChatEndpointAndRoles() throws {
        let history = VoiceConversationContext.messages(from: [conversationExchange()])
        let request = try OllamaPostProcessingService.makeStreamingChatRequest(
            text: "What about my IDE?",
            baseURL: "http://127.0.0.1:11434",
            model: "gemma4:e4b",
            instructions: "Answer clearly.",
            history: history
        )

        XCTAssertEqual(request.url?.path, "/api/chat")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, [
            "system",
            "user",
            "assistant",
            "user",
        ])
        XCTAssertEqual(messages.last?["content"], "What about my IDE?")
    }

    func testCodexRequestIncludesCustomSystemPromptWithoutWeakeningReadOnlyRules() {
        let prompt = CodexToolService.requestPrompt(
            userPrompt: "Summarize this project.",
            systemPrompt: "Answer like a patient teacher."
        )

        XCTAssertTrue(prompt.contains("Do not modify files"))
        XCTAssertTrue(prompt.contains("when they do not conflict with these read-only restrictions"))
        XCTAssertTrue(prompt.contains("Answer like a patient teacher."))
        XCTAssertTrue(prompt.contains("Summarize this project."))
    }

    func testCodexRequestIncludesOnlyExplicitlyProvidedProjectHistory() {
        let prompt = CodexToolService.requestPrompt(
            userPrompt: "What about its tests?",
            systemPrompt: "Be direct.",
            conversationHistory: [
                conversationExchange(
                    user: "What does this project do?",
                    assistant: "It is a dictation app."
                )
            ]
        )

        XCTAssertTrue(prompt.contains("Previous completed exchanges for this same selected project"))
        XCTAssertTrue(prompt.contains("User: What does this project do?"))
        XCTAssertTrue(prompt.contains("Assistant: It is a dictation app."))
        XCTAssertTrue(prompt.contains("Current user request:\nWhat about its tests?"))
    }

    func testAppleTranscriptReplaysConversationRolesWhenAvailable() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("Foundation Models transcripts require macOS 26.")
        }
        let history = VoiceConversationContext.messages(from: [conversationExchange()])

        let transcript = VoiceAgentService.appleTranscript(
            systemPrompt: "Answer clearly.",
            history: history
        )

        XCTAssertEqual(transcript.count, 3)
        let transcriptDescription = transcript.map(\.description).joined(separator: "\n")
        XCTAssertTrue(transcriptDescription.contains("Answer clearly."))
        XCTAssertTrue(transcriptDescription.contains("What is my favorite editor?"))
        XCTAssertTrue(transcriptDescription.contains("Your favorite editor is Xcode."))
    }

    @MainActor
    func testPlaybackTimelineRevealsWordsFromAudioProgress() {
        let timeline = SpokenResponsePlaybackTimeline(text: "Hello there, friend.")

        XCTAssertEqual(timeline.text(at: 0), "")
        XCTAssertEqual(timeline.text(at: 0.1), "Hello")
        XCTAssertEqual(timeline.text(at: 0.3), "Hello there,")
        XCTAssertEqual(timeline.text(at: 1), "Hello there, friend.")
    }

    @MainActor
    func testPlaybackTimelineHandlesEmptyTextAndClampsProgress() {
        XCTAssertEqual(SpokenResponsePlaybackTimeline(text: "").text(at: 0.5), "")

        let timeline = SpokenResponsePlaybackTimeline(text: "One response.")
        XCTAssertEqual(timeline.text(at: -1), "")
        XCTAssertEqual(timeline.text(at: 2), "One response.")
    }

    func testReadAloudProgressUsesSpokenWordsAndCompletesExactly() {
        let total = "One two three four five six seven eight."

        XCTAssertEqual(
            ReadAloudPlaybackProgress.fraction(
                playedText: "One two three four",
                totalText: total,
                isComplete: false
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReadAloudPlaybackProgress.fraction(
                playedText: total,
                totalText: total,
                isComplete: true
            ),
            1
        )
    }

    func testReadAloudResumeContinuesAfterLastPlayedWord() {
        let total = "One two three. Four five six. Seven eight."

        XCTAssertEqual(
            ReadAloudPlaybackProgress.remainingText(
                in: total,
                afterPlayedWordCount: 4
            ),
            "five six. Seven eight."
        )
        XCTAssertEqual(
            ReadAloudPlaybackProgress.remainingText(
                in: total,
                afterPlayedWordCount: 0
            ),
            total
        )
        XCTAssertEqual(
            ReadAloudPlaybackProgress.remainingText(
                in: total,
                afterPlayedWordCount: 20
            ),
            ""
        )
    }

    @MainActor
    func testReadAloudPauseAndStopStateTransitions() {
        let appState = AppState()
        appState.isReadAloudInProgress = true
        appState.isSpeechOutputInProgress = true
        appState.status = .processing

        appState.pauseReadAloud()

        XCTAssertFalse(appState.isReadAloudInProgress)
        XCTAssertTrue(appState.isReadAloudPaused)
        XCTAssertFalse(appState.isSpeechOutputInProgress)
        XCTAssertEqual(appState.status, .idle)

        appState.stopReadAloud()

        XCTAssertFalse(appState.isReadAloudInProgress)
        XCTAssertFalse(appState.isReadAloudPaused)
        XCTAssertEqual(appState.status, .idle)
    }

    func testOpenRouterSpeechCatalogDecodesModelsAndVoices() throws {
        let data = Data(
            """
            {
              "data": [
                {
                  "id": "qwen/qwen-audio-3.0-tts-flash",
                  "name": "Qwen: Qwen-Audio-3.0-TTS Flash",
                  "description": "Fast speech",
                  "supported_voices": ["loongjohn", "longanhuan_v3.6"],
                  "pricing": {"prompt": "0.000015"}
                },
                {
                  "id": "microsoft/mai-voice-2-flash",
                  "name": "Microsoft: MAI-Voice-2-Flash",
                  "description": "Low-latency speech",
                  "supported_voices": ["en-US-Harper:MAI-Voice-2"],
                  "pricing": {"prompt": "0.000015"}
                }
              ]
            }
            """.utf8
        )

        let models = try OpenRouterSpeechService.decodeModels(from: data)

        XCTAssertEqual(models.map(\.id), [
            "microsoft/mai-voice-2-flash",
            "qwen/qwen-audio-3.0-tts-flash",
        ])
        XCTAssertEqual(models[1].supportedVoices, ["loongjohn", "longanhuan_v3.6"])
        XCTAssertEqual(models[1].priceSummary, "$15.00 / 1M characters")
    }

    func testOpenRouterSpeechRequestUsesDedicatedTTSEndpoint() throws {
        let request = try OpenRouterSpeechService.makeSpeechRequest(
            text: "Hello world.",
            model: "qwen/qwen-audio-3.0-tts-flash",
            voice: "loongjohn",
            apiKey: "sk-or-test"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/speech")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "audio/mpeg")

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(payload["input"] as? String, "Hello world.")
        XCTAssertEqual(payload["model"] as? String, "qwen/qwen-audio-3.0-tts-flash")
        XCTAssertEqual(payload["voice"] as? String, "loongjohn")
        XCTAssertEqual(payload["response_format"] as? String, "mp3")
    }

    func testOpenRouterSpeechRetries429AndHonorsRetryAfter() async throws {
        let harness = OpenRouterSpeechRetryTestHarness()

        let audio = try await OpenRouterSpeechService.synthesize(
            text: "Hello world.",
            model: "microsoft/mai-voice-2",
            voice: "en-US-Harper:MAI-Voice-2",
            apiKey: "sk-or-test",
            apiKeyEnvironmentVariable: "",
            dataLoader: { request in
                try await harness.load(request)
            },
            sleep: { delay in
                await harness.recordSleep(delay)
            }
        )

        let requestCount = await harness.requestCount
        let sleepDelays = await harness.sleepDelays
        XCTAssertEqual(audio, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(sleepDelays, [3])
    }

    func testOpenRouterSpeechUsesSingleFallbackDelayWithoutHeader() {
        XCTAssertEqual(
            OpenRouterSpeechService.retryDelay(
                retryAfterHeader: nil
            ),
            2
        )
    }

    func testOpenRouterSpeechStopsAfterBounded429Retries() async {
        let harness = OpenRouterSpeechRetryTestHarness(successOnRequest: nil)

        do {
            _ = try await OpenRouterSpeechService.synthesize(
                text: "Hello world.",
                model: "microsoft/mai-voice-2",
                voice: "en-US-Harper:MAI-Voice-2",
                apiKey: "sk-or-test",
                apiKeyEnvironmentVariable: "",
                dataLoader: { request in
                    try await harness.load(request)
                },
                sleep: { delay in
                    await harness.recordSleep(delay)
                }
            )
            XCTFail("Expected a bounded rate-limit error.")
        } catch let error as OpenRouterSpeechService.ServiceError {
            XCTAssertEqual(
                error.localizedDescription,
                "The speech provider is rate-limited. Try again in 3 seconds or choose another speech model."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await harness.requestCount
        let sleepDelays = await harness.sleepDelays
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(sleepDelays, [3])
    }

    func testOpenRouterSpeechRequiresModelAndVoice() {
        XCTAssertThrowsError(
            try OpenRouterSpeechService.makeSpeechRequest(
                text: "Hello",
                model: "",
                voice: "alloy",
                apiKey: "sk-or-test"
            )
        )
        XCTAssertThrowsError(
            try OpenRouterSpeechService.makeSpeechRequest(
                text: "Hello",
                model: "model",
                voice: "",
                apiKey: "sk-or-test"
            )
        )
    }

    @MainActor
    func testPocketStreamingPCMBufferPreservesFluidAudioFrames() throws {
        let samples: [Float] = [0.25, -0.5, 0.75]
        let buffer = try makePocketStreamingPCMBuffer(from: samples)

        XCTAssertEqual(buffer.format.sampleRate, 24_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertEqual(buffer.floatChannelData?[0][0], samples[0])
        XCTAssertEqual(buffer.floatChannelData?[0][1], samples[1])
        XCTAssertEqual(buffer.floatChannelData?[0][2], samples[2])
    }

    @MainActor
    func testBufferedSpeechAudioDecodesIntoContinuousPlaybackSlices() throws {
        let samples = (0..<5_000).map { index in
            Float(index % 100) / 100
        }
        let wavData = try AudioWAV.data(
            from: samples,
            sampleRate: 24_000,
            normalize: false
        )

        let decoded = try decodeSpeechAudioData(wavData)
        let slices = try speechPCMBufferSlices(decoded)

        XCTAssertEqual(decoded.format.sampleRate, 24_000)
        XCTAssertEqual(decoded.format.channelCount, 1)
        XCTAssertEqual(slices.count, 3)
        XCTAssertEqual(
            slices.reduce(0) { $0 + Int($1.frameLength) },
            samples.count
        )
        XCTAssertEqual(slices[0].frameLength, 1_920)
        XCTAssertEqual(slices[1].frameLength, 1_920)
        XCTAssertEqual(slices[2].frameLength, 1_160)
        XCTAssertEqual(
            slices[0].floatChannelData?[0][99] ?? 0,
            samples[99],
            accuracy: 0.0001
        )
        XCTAssertEqual(
            slices[2].floatChannelData?[0][0] ?? 0,
            samples[3_840],
            accuracy: 0.0001
        )
    }

    func testPocketStreamingPlaybackWaitsForAllScheduledAudio() {
        let state = PocketStreamingPlaybackState()
        let frameSamples = Int64(PocketTtsConstants.samplesPerFrame)

        state.didSchedule(sampleCount: frameSamples)
        state.didSchedule(sampleCount: frameSamples)
        state.didPlay(sampleCount: frameSamples)

        XCTAssertEqual(state.scheduledFrameCount, 2)
        XCTAssertTrue(state.hasScheduledAudio)
        XCTAssertFalse(
            state.snapshot(estimatedTotalSamples: frameSamples * 4).isComplete
        )

        state.didFinishSynthesis()
        let halfway = state.snapshot(estimatedTotalSamples: frameSamples * 4)
        XCTAssertEqual(halfway.progress, 0.5, accuracy: 0.001)
        XCTAssertFalse(halfway.isComplete)

        state.didPlay(sampleCount: frameSamples)
        XCTAssertEqual(
            state.snapshot(estimatedTotalSamples: frameSamples * 4),
            PocketStreamingPlaybackSnapshot(progress: 1, isComplete: true)
        )
    }

    func testPocketStreamingProgressEstimateAccountsForPunctuation() {
        let plain = PocketStreamingPlaybackProgress.estimatedTotalSamples(
            for: "This is a short response"
        )
        let punctuated = PocketStreamingPlaybackProgress.estimatedTotalSamples(
            for: "This is, a short response."
        )

        XCTAssertGreaterThan(punctuated, plain)
    }

    func testPocketStreamingPhrasePreviewAdvancesWithPlayedAudio() {
        let state = StreamingPhrasePlaybackState()
        let phrase = "The preview should follow each spoken word naturally."
        let frameSamples = Int64(PocketTtsConstants.samplesPerFrame)

        XCTAssertEqual(state.register(phrase), 0)
        for _ in 0..<12 {
            state.didSchedule(utteranceIndex: 0, sampleCount: frameSamples)
        }
        state.didFinishGeneration()

        var latestText = state.playbackText(
            utteranceIndex: 0,
            sampleCount: frameSamples
        )
        XCTAssertNotNil(latestText)
        XCTAssertNotEqual(latestText, phrase)

        for _ in 1..<12 {
            latestText = state.playbackText(
                utteranceIndex: 0,
                sampleCount: frameSamples
            ) ?? latestText
        }
        XCTAssertEqual(latestText, phrase)
    }

    func testStreamingPhraseAccumulatorHoldsVeryShortFirstSentence() {
        var accumulator = StreamingSpeechPhraseAccumulator()

        XCTAssertEqual(accumulator.ingest("Yes."), [])
        XCTAssertEqual(
            accumulator.ingest(
                "Yes. This second sentence is deliberately long enough to provide a natural and stable speaking boundary."
            ),
            [
                "Yes. This second sentence is deliberately long enough to provide a natural and stable speaking boundary."
            ]
        )
    }

    func testStreamingPhraseAccumulatorStartsWithShortNaturalSentence() {
        var accumulator = StreamingSpeechPhraseAccumulator()
        let sentence = "Speaking can begin right away."

        XCTAssertEqual(accumulator.ingest(sentence), [sentence])
    }

    func testStreamingPhraseAccumulatorEmitsOnlyNewCumulativeText() {
        var accumulator = StreamingSpeechPhraseAccumulator()
        let first =
            "This complete opening sentence contains enough words to begin speaking naturally."
        let second =
            " The following complete sentence should be enqueued exactly once as well."

        XCTAssertEqual(accumulator.ingest(first), [first])
        XCTAssertEqual(accumulator.ingest(first), [])
        XCTAssertEqual(accumulator.ingest(first + second), [
            second.trimmingCharacters(in: .whitespaces)
        ])
        XCTAssertEqual(accumulator.finish(), [])
    }

    func testStreamingPhraseAccumulatorUsesLongClauseBoundary() {
        var accumulator = StreamingSpeechPhraseAccumulator()
        let text = """
        This intentionally extended sentence keeps adding useful context so the accumulator has enough material to start speaking at a safe clause boundary, while the model continues generating the rest
        """

        XCTAssertEqual(
            accumulator.ingest(text),
            [
                "This intentionally extended sentence keeps adding useful context so the accumulator has enough material to start speaking at a safe clause boundary,"
            ]
        )
        XCTAssertEqual(
            accumulator.finish(),
            ["while the model continues generating the rest"]
        )
    }

    func testStreamingPhraseAccumulatorFlushesShortFinalResponse() {
        var accumulator = StreamingSpeechPhraseAccumulator()

        XCTAssertEqual(accumulator.ingest("A final answer."), [])
        XCTAssertEqual(accumulator.finish(), ["A final answer."])
    }

    func testStreamingPhraseAccumulatorAcceptsCompletePastedDocuments() {
        var accumulator = StreamingSpeechPhraseAccumulator()
        let text = [
            "This opening sentence contains enough words to start the pasted document naturally.",
            "The middle sentence provides another complete semantic boundary for continuous speech playback.",
            "This final sentence confirms that every part of the pasted text remains in order.",
        ].joined(separator: " ")

        let phrases = accumulator.ingest(text) + accumulator.finish()

        XCTAssertGreaterThan(phrases.count, 1)
        XCTAssertEqual(phrases.joined(separator: " "), text)
    }

    func testOpenRouterSpeechChunksKeepFastStartAndBatchRemainingText() {
        var accumulator = OpenRouterSpeechChunkAccumulator()
        let sourcePhrases = (1...12).map { index in
            "Sentence \(index) contains enough descriptive words to represent a natural speech synthesis boundary."
        }
        var chunks: [String] = []
        for phrase in sourcePhrases {
            chunks.append(contentsOf: accumulator.ingest(phrase))
        }
        chunks.append(contentsOf: accumulator.finish())

        XCTAssertEqual(chunks[0], sourcePhrases[0])
        XCTAssertEqual(chunks[1], sourcePhrases[1])
        XCTAssertLessThanOrEqual(chunks.count, 4)
        XCTAssertEqual(
            chunks.joined(separator: " "),
            sourcePhrases.joined(separator: " ")
        )
    }

    func testStreamingSynthesisLookaheadWaitsForPlaybackRelease() async throws {
        let gate = StreamingSynthesisLookaheadGate(
            maximumOutstandingChunks: 2
        )
        let thirdAcquireCompleted = VoiceAgentTestFlag()
        try await gate.acquire()
        try await gate.acquire()

        let waitingTask = Task {
            try await gate.acquire()
            await thirdAcquireCompleted.set()
        }
        try await Task.sleep(for: .milliseconds(60))
        let completedBeforeRelease = await thirdAcquireCompleted.value
        XCTAssertFalse(completedBeforeRelease)

        await gate.release()
        try await Task.sleep(for: .milliseconds(60))
        let completedAfterRelease = await thirdAcquireCompleted.value
        XCTAssertTrue(completedAfterRelease)
        waitingTask.cancel()
    }

    @MainActor
    func testKokoroAneInstalledModelSynthesizesPhraseSizedBuffers() async throws {
        guard ProcessInfo.processInfo.environment[
            "DICTATE_ANYWHERE_RUN_BUFFERED_STREAMING_INTEGRATION"
        ] == "1" else {
            throw XCTSkip("Set the buffered-streaming integration flag to load KokoroAne.")
        }

        let manager = KokoroAneManager(
            defaultVoice: KokoroAneConstants.defaultVoice
        )
        try await manager.initialize()

        let firstStartedAt = ContinuousClock.now
        let first = try await manager.synthesizeDetailed(
            text: "The first phrase starts playing while the next phrase is synthesized."
        )
        let firstSynthesisTime = ContinuousClock.now - firstStartedAt

        let secondStartedAt = ContinuousClock.now
        let second = try await manager.synthesizeDetailed(
            text: "The second phrase can then be scheduled directly behind it."
        )
        let secondSynthesisTime = ContinuousClock.now - secondStartedAt

        XCTAssertFalse(first.samples.isEmpty)
        XCTAssertFalse(second.samples.isEmpty)
        XCTAssertEqual(first.sampleRate, second.sampleRate)
        print(
            "KokoroAne phrase timing:",
            firstSynthesisTime,
            secondSynthesisTime,
            "audio:",
            Double(first.samples.count) / Double(first.sampleRate),
            Double(second.samples.count) / Double(second.sampleRate)
        )
    }

    func testPocketTTSInstalledModelYieldsAudioBeforeSynthesisCompletes() async throws {
        guard ProcessInfo.processInfo.environment[
            "DICTATE_ANYWHERE_RUN_POCKET_STREAMING_INTEGRATION"
        ] == "1" else {
            throw XCTSkip("Set the PocketTTS integration flag to load the installed Core ML models.")
        }

        let manager = PocketTtsManager(
            defaultVoice: PocketTtsConstants.defaultVoice,
            language: .english,
            precision: .int8,
            placement: .gpu
        )
        try await manager.initialize()

        let startedAt = ContinuousClock.now
        let session = try await manager.makeSession(
            voice: PocketTtsConstants.defaultVoice
        )
        session.enqueue(
            "Pocket TTS should begin speaking this first phrase while more text is still arriving."
        )
        var iterator = session.frames.makeAsyncIterator()
        let firstFrame = try await iterator.next()
        let firstFrameLatency = ContinuousClock.now - startedAt

        XCTAssertEqual(
            firstFrame?.samples.count,
            PocketTtsConstants.samplesPerFrame
        )

        session.enqueue(
            "This second phrase arrived after the first audio frame and should continue in the same session."
        )
        session.finish()

        var frameCount = firstFrame == nil ? 0 : 1
        var utteranceIndexes = Set(firstFrame?.utteranceIndex.map { [$0] } ?? [])
        while let frame = try await iterator.next() {
            XCTAssertEqual(frame.samples.count, PocketTtsConstants.samplesPerFrame)
            if let utteranceIndex = frame.utteranceIndex {
                utteranceIndexes.insert(utteranceIndex)
            }
            frameCount += 1
        }
        let totalSynthesisTime = ContinuousClock.now - startedAt

        XCTAssertGreaterThan(frameCount, 1)
        XCTAssertEqual(utteranceIndexes, [0, 1])
        XCTAssertLessThan(firstFrameLatency, totalSynthesisTime)
        XCTAssertGreaterThan(
            totalSynthesisTime - firstFrameLatency,
            .milliseconds(250),
            "The first frame should arrive while substantial synthesis work remains."
        )
    }
}
