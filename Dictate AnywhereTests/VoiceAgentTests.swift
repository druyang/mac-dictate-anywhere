import AVFoundation
import FluidAudio
import XCTest
@testable import Dictate_Anywhere_Dev

private actor VoiceAgentTestFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

final class VoiceAgentTests: XCTestCase {
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
        let stream = try await manager.synthesizeStreaming(
            text: "Pocket TTS should begin speaking this response before every audio frame has finished generating."
        )
        var iterator = stream.makeAsyncIterator()
        let firstFrame = try await iterator.next()
        let firstFrameLatency = ContinuousClock.now - startedAt

        XCTAssertEqual(
            firstFrame?.samples.count,
            PocketTtsConstants.samplesPerFrame
        )

        var frameCount = firstFrame == nil ? 0 : 1
        while let frame = try await iterator.next() {
            XCTAssertEqual(frame.samples.count, PocketTtsConstants.samplesPerFrame)
            frameCount += 1
        }
        let totalSynthesisTime = ContinuousClock.now - startedAt

        XCTAssertGreaterThan(frameCount, 1)
        XCTAssertLessThan(firstFrameLatency, totalSynthesisTime)
        XCTAssertGreaterThan(
            totalSynthesisTime - firstFrameLatency,
            .milliseconds(250),
            "The first frame should arrive while substantial synthesis work remains."
        )
    }
}
