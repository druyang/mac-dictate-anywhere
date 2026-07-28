import XCTest
@testable import Dictate_Anywhere_Dev

final class ReadAloudDocumentTests: XCTestCase {
    func testTokenizesParagraphsAndStripsMarkdownScaffolding() {
        let document = ReadAloudDocument(
            source: """
            # Key Findings

            - The **demand** is real.
            - Pricing supports a `good` living.
            """
        )

        XCTAssertEqual(document.paragraphs.count, 3)
        XCTAssertEqual(
            document.words.map(\.text),
            ["Key", "Findings", "The", "demand", "is", "real.", "Pricing",
             "supports", "a", "good", "living."]
        )
        XCTAssertEqual(document.words[0].paragraph, 0)
        XCTAssertEqual(document.words[2].paragraph, 1)
    }

    func testSpokenTextMatchesWordIndicesSoSeekingIsExact() {
        let document = ReadAloudDocument(source: "One two three. Four five six.")

        XCTAssertEqual(document.wordCount, 6)
        XCTAssertEqual(document.spokenText(), "One two three. Four five six.")
        XCTAssertEqual(document.spokenText(from: 3), "Four five six.")
        XCTAssertEqual(document.spokenText(from: 6), "")
    }

    func testSentencesSplitOnPunctuationButNotOnAbbreviations() {
        let document = ReadAloudDocument(
            source: "Dr. Smith arrived. He left, e.g. quickly. Done!"
        )

        XCTAssertEqual(document.sentenceCount, 3)
        XCTAssertEqual(document.sentenceStarts, [0, 3, 7])
        XCTAssertEqual(document.sentence(containing: 4), 1)
    }

    func testLineBreakEndsASentenceEvenWithoutPunctuation() {
        let document = ReadAloudDocument(source: "A heading\nA following line.")

        XCTAssertEqual(document.sentenceCount, 2)
        XCTAssertEqual(document.sentenceStarts, [0, 2])
    }

    func testPreviousSentenceRestartsCurrentSentenceBeforeSteppingBack() {
        let document = ReadAloudDocument(source: "One two three four. Five six seven eight.")

        // Deep into the second sentence: restart it.
        XCTAssertEqual(document.previousSentenceStart(from: 7), 4)
        // Only just inside it: step back to the previous sentence.
        XCTAssertEqual(document.previousSentenceStart(from: 5), 0)
        // Already in the first sentence: stay at the top.
        XCTAssertEqual(document.previousSentenceStart(from: 1), 0)
    }

    func testNextSentenceStopsPastTheLastWord() {
        let document = ReadAloudDocument(source: "One two. Three four.")

        XCTAssertEqual(document.nextSentenceStart(from: 0), 2)
        XCTAssertEqual(document.nextSentenceStart(from: 3), document.wordCount)
    }

    func testEmptySourceProducesEmptyDocument() {
        let document = ReadAloudDocument(source: "   \n\n  ")

        XCTAssertTrue(document.isEmpty)
        XCTAssertEqual(document.wordCount, 0)
        XCTAssertEqual(document.spokenText(), "")
        XCTAssertEqual(document.clampedWordIndex(5), 0)
    }

    func testDurationLabelsRoundToReadableValues() {
        XCTAssertEqual(
            ReadAloudDocument.approximateDurationLabel(seconds: 25),
            "about 25 s"
        )
        XCTAssertEqual(
            ReadAloudDocument.approximateDurationLabel(seconds: 120),
            "about 2 min"
        )
        XCTAssertEqual(
            ReadAloudDocument.approximateDurationLabel(seconds: 162),
            "about 2 min 40 s"
        )
    }

    @MainActor
    func testSeekMovesReadingPositionWithoutStartingPlayback() {
        let appState = AppState()
        appState.readAloudText = "One two three. Four five six."

        appState.seekReadAloud(toWordIndex: 4)

        XCTAssertEqual(appState.readAloudWordIndex, 4)
        XCTAssertEqual(appState.readAloudHighlightIndex, 4)
        XCTAssertFalse(appState.isReadAloudInProgress)
        XCTAssertEqual(appState.readAloudProgress, 4.0 / 6.0, accuracy: 0.001)
    }

    @MainActor
    func testSentenceSkipMovesBetweenSentenceStarts() {
        let appState = AppState()
        appState.readAloudText = "One two three. Four five six. Seven eight."

        appState.skipReadAloudSentence(by: 1)
        XCTAssertEqual(appState.readAloudWordIndex, 3)

        appState.skipReadAloudSentence(by: 1)
        XCTAssertEqual(appState.readAloudWordIndex, 6)

        appState.skipReadAloudSentence(by: -1)
        XCTAssertEqual(appState.readAloudWordIndex, 3)
    }

    @MainActor
    func testSkippingPastTheLastSentenceFinishesTheReading() {
        let appState = AppState()
        appState.readAloudText = "One two. Three four."
        appState.seekReadAloud(toWordIndex: 2)

        appState.skipReadAloudSentence(by: 1)

        XCTAssertTrue(appState.isReadAloudFinished)
        XCTAssertEqual(appState.readAloudProgress, 1)
    }

    @MainActor
    func testEditingTextResetsPositionAndDocument() {
        let appState = AppState()
        appState.readAloudText = "One two three. Four five six."
        appState.seekReadAloud(toWordIndex: 4)

        appState.readAloudText = "Something else entirely."

        XCTAssertEqual(appState.readAloudWordIndex, 0)
        XCTAssertEqual(appState.readAloudDocument.wordCount, 3)
        XCTAssertFalse(appState.isReadAloudFinished)
    }

    /// A late callback for an earlier phrase must not report a position behind
    /// one already reported — that regression is what yanked the reader's
    /// highlight, and the scroll position, back to the top mid-playback.
    func testPlaybackTextNeverReportsAPositionThatMovedBackwards() {
        let state = StreamingPhrasePlaybackState()
        let first = state.register("One two three four.")
        let second = state.register("Five six seven eight.")

        state.didSchedule(utteranceIndex: first, sampleCount: 48_000)
        state.didSchedule(utteranceIndex: second, sampleCount: 48_000)

        let advanced = state.playbackText(
            utteranceIndex: second,
            sampleCount: 48_000
        )
        XCTAssertNotNil(advanced)
        XCTAssertTrue(advanced?.hasPrefix("One two three four.") == true)

        // The stale callback for the first phrase is dropped, not reported.
        XCTAssertNil(state.playbackText(utteranceIndex: first, sampleCount: 1))
    }

    /// The editor mode lives on AppState, not in view state, so the window's
    /// warning banners appearing underneath the page can't drop an edit session.
    @MainActor
    func testEditingModeSurvivesOnAppStateAndClearsWithTheText() {
        let appState = AppState()
        XCTAssertFalse(appState.isEditingReadAloudText)

        appState.isEditingReadAloudText = true
        appState.readAloudText = "Typed straight in."
        XCTAssertTrue(appState.isEditingReadAloudText)
        XCTAssertEqual(appState.readAloudDocument.wordCount, 3)

        appState.clearReadAloudText()
        XCTAssertFalse(appState.isEditingReadAloudText)
    }

    @MainActor
    func testClearResetsDocumentAndPosition() {
        let appState = AppState()
        appState.readAloudText = "One two three."
        appState.seekReadAloud(toWordIndex: 2)

        appState.clearReadAloudText()

        XCTAssertTrue(appState.readAloudDocument.isEmpty)
        XCTAssertEqual(appState.readAloudWordIndex, 0)
        XCTAssertEqual(appState.readAloudProgress, 0)
    }
}
