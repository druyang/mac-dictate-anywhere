import XCTest
@testable import Dictate_Anywhere_Dev

final class ModelAndModeTests: XCTestCase {

    // MARK: - ParakeetModelChoice

    func testAllModelChoicesHaveMetadata() {
        for choice in ParakeetModelChoice.allCases {
            XCTAssertFalse(choice.displayName.isEmpty, "\(choice) missing displayName")
            XCTAssertFalse(choice.detail.isEmpty, "\(choice) missing detail")
            XCTAssertFalse(choice.sizeSummary.isEmpty, "\(choice) missing sizeSummary")
            XCTAssertFalse(choice.languageSummary.isEmpty, "\(choice) missing languageSummary")
        }
    }

    func testModelChoiceLanguageSummaryMatchesEnglishOnlyFlag() {
        for choice in ParakeetModelChoice.allCases {
            if choice.isEnglishOnly {
                XCTAssertEqual(choice.languageSummary, "English only")
            } else {
                XCTAssertNotEqual(choice.languageSummary, "English only")
            }
        }
    }

    func testMultilingualIsNotEnglishOnly() {
        XCTAssertFalse(ParakeetModelChoice.multilingual.isEnglishOnly)
        XCTAssertTrue(ParakeetModelChoice.englishOnly.isEnglishOnly)
    }

    func testStreamingModelsUseTrueStreaming() {
        XCTAssertTrue(ParakeetModelChoice.nemotron2240.usesTrueStreaming)
        XCTAssertFalse(ParakeetModelChoice.multilingual.usesTrueStreaming)
    }

    func testModelChoiceRawValuesRoundTrip() {
        for choice in ParakeetModelChoice.allCases {
            XCTAssertEqual(ParakeetModelChoice(rawValue: choice.rawValue), choice)
        }
    }

    // MARK: - TranscriptionEngineChoice

    func testEngineDisplayName() {
        XCTAssertEqual(TranscriptionEngineChoice.parakeet.displayName, "FluidAudio")
        XCTAssertEqual(TranscriptionEngineChoice.appleSpeech.displayName, "Apple Speech")
    }

    func testEngineChoicesHaveMetadataAndStableRawValues() {
        XCTAssertEqual(TranscriptionEngineChoice.allCases, [.parakeet, .appleSpeech])
        for choice in TranscriptionEngineChoice.allCases {
            XCTAssertFalse(choice.displayName.isEmpty)
            XCTAssertFalse(choice.detail.isEmpty)
            XCTAssertEqual(TranscriptionEngineChoice(rawValue: choice.rawValue), choice)
        }
    }

    // MARK: - TranscriptPostProcessingMode

    func testPostProcessingModeDisplayNames() {
        XCTAssertEqual(TranscriptPostProcessingMode.none.displayName, "None")
        XCTAssertEqual(TranscriptPostProcessingMode.fluidAudioVocabulary.displayName, "FluidAudio Vocabulary")
        XCTAssertEqual(TranscriptPostProcessingMode.appleIntelligence.displayName, "Apple Intelligence")
        XCTAssertEqual(TranscriptPostProcessingMode.ollama.displayName, "Ollama")
        XCTAssertEqual(TranscriptPostProcessingMode.openRouter.displayName, "OpenRouter")
        XCTAssertEqual(TranscriptPostProcessingMode.openAICompatible.displayName, "OpenAI Compatible")
    }

    func testPostProcessingModeRoundTrip() {
        for mode in TranscriptPostProcessingMode.allCases {
            XCTAssertEqual(TranscriptPostProcessingMode(rawValue: mode.rawValue), mode)
        }
    }

    // MARK: - Voice assistant

    func testAgentBrainProvidersHaveStableNamesAndRawValues() {
        XCTAssertEqual(
            AgentBrainProvider.allCases,
            [.appleIntelligence, .ollama, .openRouter]
        )
        XCTAssertEqual(AgentBrainProvider.appleIntelligence.displayName, "Apple Intelligence")
        XCTAssertEqual(AgentBrainProvider.ollama.displayName, "Ollama")
        XCTAssertEqual(AgentBrainProvider.openRouter.displayName, "OpenRouter")

        for provider in AgentBrainProvider.allCases {
            XCTAssertEqual(AgentBrainProvider(rawValue: provider.rawValue), provider)
        }
    }

    // MARK: - Speech synthesis

    func testSpeechSynthesisModelsHaveCompleteMetadata() {
        XCTAssertEqual(
            SpeechSynthesisModel.allCases,
            [.supertonic3, .kokoroAne, .pocketTTS, .openRouter]
        )

        for model in SpeechSynthesisModel.allCases {
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertFalse(model.detail.isEmpty)
            XCTAssertFalse(model.languageSummary.isEmpty)
            XCTAssertFalse(model.sampleRateSummary.isEmpty)
            XCTAssertFalse(model.licenseSummary.isEmpty)
            XCTAssertFalse(model.sizeSummary.isEmpty)
            XCTAssertEqual(SpeechSynthesisModel(rawValue: model.rawValue), model)
        }

        XCTAssertEqual(SpeechSynthesisModel.localCases, [.supertonic3, .kokoroAne, .pocketTTS])
        XCTAssertTrue(SpeechSynthesisModel.localCases.allSatisfy { $0.expectedDownloadBytes > 0 })
        XCTAssertFalse(SpeechSynthesisModel.openRouter.isLocal)
        XCTAssertEqual(SpeechSynthesisModel.openRouter.expectedDownloadBytes, 0)
    }

    func testSpeechVoiceChoicesHaveUniqueStableRawValues() {
        XCTAssertEqual(SupertonicVoiceChoice.allCases.count, 10)
        XCTAssertEqual(PocketVoiceChoice.allCases.count, 4)

        for voice in SupertonicVoiceChoice.allCases {
            XCTAssertFalse(voice.displayName.isEmpty)
            XCTAssertEqual(SupertonicVoiceChoice(rawValue: voice.rawValue), voice)
        }

        for voice in PocketVoiceChoice.allCases {
            XCTAssertFalse(voice.displayName.isEmpty)
            XCTAssertEqual(PocketVoiceChoice(rawValue: voice.rawValue), voice)
        }
    }

    func testSpeechOutputLanguagesAreCompleteAndStable() {
        XCTAssertEqual(SpeechOutputLanguage.allCases.count, 31)
        XCTAssertEqual(SpeechOutputLanguage.english.rawValue, "en")
        XCTAssertEqual(
            Set(SpeechOutputLanguage.allCases.map(\.rawValue)).count,
            SpeechOutputLanguage.allCases.count
        )

        for language in SpeechOutputLanguage.allCases {
            XCTAssertFalse(language.displayName.isEmpty)
            XCTAssertEqual(SpeechOutputLanguage(rawValue: language.rawValue), language)
        }
    }

    func testSpeechReadinessWarningExplainsMissingLocalModel() {
        XCTAssertEqual(
            SpeechReadinessWarning.message(for: .supertonic3, isReady: false),
            "Supertonic-3 isn’t downloaded. Download it before the Voice Assistant can speak responses."
        )
        XCTAssertNil(
            SpeechReadinessWarning.message(for: .supertonic3, isReady: true)
        )
    }

    func testSpeechReadinessWarningExplainsIncompleteOpenRouterSetup() {
        XCTAssertEqual(
            SpeechReadinessWarning.message(for: .openRouter, isReady: false),
            "OpenRouter speech isn’t ready. Add the shared API key, then choose a speech model and voice."
        )
    }

    // MARK: - AppAppearanceMode

    func testAppAppearanceModes() {
        XCTAssertEqual(AppAppearanceMode.menuBarOnly.displayName, "Menu Bar Only")
        XCTAssertEqual(AppAppearanceMode.dockAndMenuBar.displayName, "Dock and Menu Bar")
        XCTAssertEqual(AppAppearanceMode.menuBarOnly.activationPolicy, .accessory)
        XCTAssertEqual(AppAppearanceMode.dockAndMenuBar.activationPolicy, .regular)
    }

    // MARK: - SupportedLanguage

    func testSupportedLanguagesHaveUniqueIDs() {
        let ids = SupportedLanguage.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testSupportedLanguagesHaveFlags() {
        for language in SupportedLanguage.allCases {
            XCTAssertFalse(language.displayWithFlag.isEmpty)
        }
    }

    func testEnglishExists() {
        XCTAssertTrue(SupportedLanguage.allCases.contains(.english))
        XCTAssertEqual(SupportedLanguage.english.rawValue, "en")
    }

    // MARK: - Sidebar pages (design conformance)

    func testSidebarPageOrderAndTitlesMatchDesign() {
        XCTAssertEqual(
            SidebarPage.allCases.map(\.title),
            [
                "Dictation Model",
                "Speech Model",
                "General",
                "Shortcuts",
                "Voice Assistant",
                "Text & Overlay",
                "Transcript Cleanup",
                "History",
                "About",
            ]
        )
    }

    func testSidebarPageIconsAreValidSFSymbols() {
        for page in SidebarPage.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: page.icon, accessibilityDescription: nil),
                "\(page.title) icon \(page.icon) is not a valid SF Symbol"
            )
        }
    }

    // MARK: - Window sizing

    func testWindowSizingMatchesDesignCanvas() {
        XCTAssertEqual(MainWindowSizing.defaultWidth, 1120)
        XCTAssertEqual(MainWindowSizing.defaultHeight, 780)
        XCTAssertLessThanOrEqual(MainWindowSizing.minimumWidth, MainWindowSizing.defaultWidth)
        XCTAssertLessThanOrEqual(MainWindowSizing.minimumHeight, MainWindowSizing.defaultHeight)
    }
}
