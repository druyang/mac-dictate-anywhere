//
//  ReadAloudView.swift
//  Dictate Anywhere
//
//  Reading surface: the pasted text becomes a document you follow along with.
//  The spoken word is highlighted, clicking a word reads from there, and the
//  player bar scrubs by word.
//

import AppKit
import SwiftUI

struct ReadAloudView: View {
    @Environment(AppState.self) private var appState

    @FocusState private var isReaderFocused: Bool

    /// Reading and editing are mutually exclusive: the document is re-parsed on
    /// every keystroke, so a playback position mid-edit would point at a word
    /// that no longer exists.
    private var isEditing: Bool { appState.isEditingReadAloudText }

    var body: some View {
        let configuration = SpeechOutputConfiguration(settings: appState.settings)
        let document = appState.readAloudDocument
        let showsReader = !document.isEmpty && !isEditing

        VStack(alignment: .leading, spacing: DS.Spacing.section) {
            DSSectionHeader(
                title: "Read Aloud",
                subtitle: showsReader
                    ? "Follow along while it reads. The spoken word is highlighted — click any word to jump there."
                    : "Paste anything you would rather listen to, then follow along while it reads."
            )

            if !configuration.isReady {
                speechModelRequired(configuration: configuration)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.overlineToCard) {
                DSOverline(text: showsReader ? "Now Reading" : "Text")

                DSCard {
                    toolbar(configuration: configuration, showsReader: showsReader)
                    DSDivider()

                    if showsReader {
                        reader(document: document)
                        DSDivider()
                        ReadAloudPlayerBar(
                            appState: appState,
                            isReady: configuration.isReady
                        )
                    } else if isEditing {
                        composer(configuration: configuration)
                    } else {
                        emptyState(configuration: configuration)
                    }

                    if let error = appState.readAloudError {
                        DSDivider()
                        DSPanel(text: error, tone: .danger)
                            .padding(DS.Spacing.rowHorizontal)
                    }
                }
                .frame(maxHeight: showsReader ? .infinity : nil)
            }
            .frame(maxHeight: showsReader ? .infinity : nil)

            DSHint(
                text: showsReader
                    ? "Click any word to read from there. Space plays or pauses, ← and → jump one sentence."
                    : "Long documents are fine — the text is split at sentence boundaries and streamed one phrase at a time.",
                icon: showsReader ? "hand.tap" : "lightbulb"
            )
        }
        .padding(.top, DS.Spacing.contentTop)
        .padding(.horizontal, DS.Spacing.contentHorizontal)
        .padding(.bottom, DS.Spacing.contentBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Colors.bgWindow)
        .task {
            appState.speechModelManager.refresh()
        }
    }

    // MARK: - Toolbar

    private func toolbar(
        configuration: SpeechOutputConfiguration,
        showsReader: Bool
    ) -> some View {
        let document = appState.readAloudDocument

        return HStack(spacing: 8) {
            DSStatusPill(
                text: statusText,
                tone: statusTone,
                dotColor: appState.isReadAloudInProgress ? DS.Colors.accent : nil,
                textColor: appState.isReadAloudInProgress ? DS.Colors.accentDeep : nil,
                fill: appState.isReadAloudInProgress ? DS.Colors.accentSoft : nil
            )

            DSChip(text: voiceLabel(for: configuration))

            if !document.isEmpty {
                DSChip(text: lengthLabel(for: document))
            }

            Spacer(minLength: 8)

            if showsReader {
                DSIconButton(
                    systemImage: "pencil",
                    accessibilityLabel: "Edit text"
                ) {
                    appState.stopReadAloud()
                    appState.isEditingReadAloudText = true
                }
            }

            DSIconButton(
                systemImage: "trash",
                accessibilityLabel: "Clear text"
            ) {
                appState.stopReadAloud()
                appState.clearReadAloudText()
                appState.isEditingReadAloudText = false
            }
            .disabled(appState.readAloudText.isEmpty)
            .opacity(appState.readAloudText.isEmpty ? 0.4 : 1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    // MARK: - Reader

    private func reader(document: ReadAloudDocument) -> some View {
        ReadAloudDocumentView(
            document: document,
            highlightIndex: appState.readAloudHighlightIndex,
            hasStarted: appState.isReadAloudInProgress
                || appState.isReadAloudPaused
                || appState.readAloudWordIndex > 0,
            isPlaying: appState.isReadAloudInProgress
        ) { wordIndex in
            appState.seekReadAloud(toWordIndex: wordIndex)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($isReaderFocused)
        .onKeyPress(.space) {
            appState.toggleReadAloud()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            appState.skipReadAloudSentence(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            appState.skipReadAloudSentence(by: 1)
            return .handled
        }
        .onAppear { isReaderFocused = true }
    }

    // MARK: - Empty state

    private func emptyState(configuration: SpeechOutputConfiguration) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(DS.Colors.accentSoft)
                    .frame(width: 52, height: 52)
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(DS.Colors.accentDeep)
            }

            Text("Nothing to read yet")
                .font(DS.Fonts.display(19))
                .foregroundStyle(DS.Colors.ink)

            Text("Paste an article, an email, a chapter — anything you would rather hear than read.")
                .font(DS.Fonts.ui(13.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            HStack(spacing: 8) {
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.dsSecondary)

                Button("Type it instead") {
                    appState.isEditingReadAloudText = true
                }
                .buttonStyle(.dsSecondary)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    // MARK: - Composer

    private func composer(configuration: SpeechOutputConfiguration) -> some View {
        let document = appState.readAloudDocument
        let canStart = !document.isEmpty
            && configuration.isReady
            && appState.status == .idle

        return VStack(alignment: .leading, spacing: 0) {
            SettingsMultilineTextArea(
                text: Binding(
                    get: { appState.readAloudText },
                    set: { appState.readAloudText = $0 }
                ),
                placeholder: "Paste an article, document, response, or any other text to read aloud…",
                minHeight: 300,
                maxHeight: 560,
                focusesOnAppear: true
            )
            .labelsHidden()
            .padding(.vertical, 14)
            .padding(.horizontal, DS.Spacing.rowHorizontal)

            DSDivider()

            HStack(spacing: 10) {
                Text(
                    document.isEmpty
                        ? "Markdown headings, bullets and emphasis are stripped before reading."
                        : lengthLabel(for: document) + " once you start."
                )
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)

                Spacer(minLength: 12)

                Button("Paste") {
                    pasteFromClipboard()
                }
                .buttonStyle(.dsSecondary)

                // Always available: with no text it is the way back out of the
                // editor, with text it is the way into the reader.
                Button("Done") {
                    appState.isEditingReadAloudText = false
                }
                .buttonStyle(.dsSecondary)

                Button {
                    appState.isEditingReadAloudText = false
                    appState.startReadAloud()
                } label: {
                    Label("Read Aloud", systemImage: "play.fill")
                }
                .buttonStyle(.dsPrimary)
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.5)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, DS.Spacing.rowHorizontal)
        }
    }

    private func pasteFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string),
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appState.readAloudError = "The clipboard has no text to read."
            return
        }
        appState.stopReadAloud()
        appState.readAloudText = pasted
        appState.readAloudError = nil
        appState.isEditingReadAloudText = false
    }

    // MARK: - Setup

    private func speechModelRequired(
        configuration: SpeechOutputConfiguration
    ) -> some View {
        DSSection(overline: "Speech Model Required") {
            VStack(alignment: .leading, spacing: 14) {
                DSPanel(
                    text: setupMessage(for: configuration),
                    tone: .warning,
                    icon: "speaker.slash"
                )

                HStack {
                    Spacer()
                    Button {
                        appState.selectedPage = .speechOutput
                    } label: {
                        Label("Set Up Speech Model", systemImage: "arrow.right")
                    }
                    .buttonStyle(.dsPrimary)
                }
            }
            .padding(DS.Spacing.rowHorizontal)
        }
    }

    // MARK: - Labels

    private var statusText: String {
        if appState.isReadAloudInProgress {
            return appState.readAloudWordIndex > 0 ? "Reading" : "Preparing"
        }
        if appState.isReadAloudPaused { return "Paused" }
        if appState.isReadAloudFinished { return "Finished" }
        if appState.readAloudDocument.isEmpty { return "No text yet" }
        return "Ready"
    }

    private var statusTone: DS.Tone {
        if appState.isReadAloudInProgress { return .info }
        if appState.isReadAloudPaused { return .warning }
        if appState.isReadAloudFinished { return .success }
        if appState.readAloudDocument.isEmpty { return .neutral }
        return .success
    }

    private func voiceLabel(for configuration: SpeechOutputConfiguration) -> String {
        configuration.model.displayName
    }

    private func lengthLabel(for document: ReadAloudDocument) -> String {
        let words = document.wordCount
        let duration = ReadAloudDocument.approximateDurationLabel(
            seconds: document.estimatedSeconds()
        )
        return "\(words) \(words == 1 ? "word" : "words") · \(duration)"
    }

    private func setupMessage(
        for configuration: SpeechOutputConfiguration
    ) -> String {
        if configuration.model.isLocal {
            return "\(configuration.model.displayName) is not downloaded. Set up a local speech model before reading text aloud."
        }
        return "OpenRouter speech is not configured. Add an API key, then choose a speech model and voice."
    }
}

// MARK: - Document

/// The scrollable word canvas. Paragraphs are lazy so a book-length paste only
/// realizes the words on screen.
private struct ReadAloudDocumentView: View {
    let document: ReadAloudDocument
    let highlightIndex: Int
    let hasStarted: Bool
    let isPlaying: Bool
    let onSeek: (Int) -> Void

    /// A word the user just clicked is already on screen; re-centring it would
    /// yank the page out from under the click. Every other move of the
    /// highlight — playback, scrubbing, sentence skips — should scroll.
    @State private var wordTappedDirectly: Int?

    /// Set while the reader is browsing elsewhere by hand. Following stops
    /// dead rather than dragging the page back mid-scroll.
    @State private var isFollowSuspended = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var scrollMonitor: Any?
    @State private var isHoveringDocument = false
    /// Bumped when the page must be brought back to the spoken word.
    @State private var resyncRequests = 0

    /// Fraction of the visible height the spoken word may reach before the page
    /// follows it. Anything above this is comfortably in view already.
    private static let followThreshold = 0.72
    /// Where a followed word lands, leaving most of a screen of unread text
    /// below it before the next nudge is due.
    private static let restingPosition = 0.4
    /// How long the page stays where the reader put it after their last scroll.
    /// Long enough to read a paragraph in peace, short enough that playback
    /// doesn't wander off unattended.
    private static let resumeFollowingAfter = Duration.seconds(8)

    var body: some View {
        let highlightSentence = document.sentence(containing: highlightIndex)
        let highlightSentenceRange = document.sentenceRange(highlightSentence)

        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(document.paragraphs) { paragraph in
                            DSWrapLayout(horizontalSpacing: 0, verticalSpacing: 3) {
                                ForEach(document.words[paragraph.range], id: \.id) { word in
                                    let appearance = appearance(
                                        for: word,
                                        highlightSentence: highlightSentence,
                                        highlightSentenceRange: highlightSentenceRange
                                    )
                                    ReadAloudWordView(
                                        text: word.text,
                                        appearance: appearance,
                                        reportsPosition: appearance.isCurrent
                                    ) {
                                        wordTappedDirectly = word.id
                                        onSeek(word.id)
                                    }
                                    .id(word.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(Self.paragraphAnchor(paragraph.id))
                        }
                    }
                    .padding(.vertical, 22)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(ReadAloudCurrentWordFrame.self) { frame in
                    follow(frame, proxy: proxy, viewportHeight: viewport.size.height)
                }
                .onChange(of: highlightIndex) { oldValue, newValue in
                    guard wordTappedDirectly != newValue else {
                        wordTappedDirectly = nil
                        return
                    }
                    wordTappedDirectly = nil
                    // Playback stepping to the next word is handled by the
                    // position check above — only a deliberate jump repositions.
                    guard abs(newValue - oldValue) > 3 else { return }
                    // Asking to go somewhere is also asking to follow again.
                    resumeFollowing()
                    jump(proxy, to: newValue)
                }
                .overlay(alignment: .bottom) {
                    if isFollowSuspended, isPlaying {
                        resyncButton()
                            .padding(.bottom, 14)
                            .transition(
                                .opacity.combined(with: .move(edge: .bottom))
                            )
                    }
                }
                .animation(.easeOut(duration: 0.2), value: isFollowSuspended)
                .onChange(of: resyncRequests) { _, _ in
                    jump(proxy, to: highlightIndex)
                }
                .onAppear { startWatchingForManualScroll() }
                .onDisappear {
                    resumeTask?.cancel()
                    resumeTask = nil
                    if let scrollMonitor {
                        NSEvent.removeMonitor(scrollMonitor)
                    }
                    scrollMonitor = nil
                }
            }
        }
        .onHover { hovering in
            isHoveringDocument = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private func resyncButton() -> some View {
        Button {
            resumeFollowing()
            resyncRequests += 1
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Jump to reading position")
                    .font(DS.Fonts.ui(12, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 7)
            .padding(.horizontal, 13)
            .background(DS.Colors.accent, in: Capsule())
            .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Scrolling by hand takes the page away from playback until the reader
    /// stops. Programmatic scrolling produces no scroll-wheel events, so this
    /// only ever sees the user's own input.
    private func startWatchingForManualScroll() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if isHoveringDocument {
                suspendFollowing()
            }
            return event
        }
    }

    private func suspendFollowing() {
        isFollowSuspended = true
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: Self.resumeFollowingAfter)
            // Only playback earns the page back. A paused reader keeps whatever
            // they scrolled to, indefinitely.
            guard !Task.isCancelled, isPlaying else { return }
            isFollowSuspended = false
            // The spoken word may be far off-screen by now, with no rendered
            // row to measure, so re-syncing has to be driven rather than left
            // to the position check.
            resyncRequests += 1
        }
    }

    private func resumeFollowing() {
        resumeTask?.cancel()
        resumeTask = nil
        isFollowSuspended = false
    }

    /// Keeps the spoken word in view *without* scrolling on every word.
    ///
    /// Scrolling per word is what made reading from the top run away: each
    /// `scrollTo` realizes more of the lazy stack, the content grows, and the
    /// next one reaches further, so the page raced ahead of the audio. Here the
    /// page only moves once the word has actually drifted past the threshold,
    /// and it lands high enough that the next nudge is many words away.
    private func follow(
        _ frame: CGRect?,
        proxy: ScrollViewProxy,
        viewportHeight: CGFloat
    ) {
        guard let frame, viewportHeight > 0 else { return }

        if isFollowSuspended {
            // Scrolled back to where the reading is? Then following can take
            // over again straight away — no need to wait out the idle delay,
            // and nothing to re-position since the word is already in view.
            let isComfortablyVisible = frame.minY > 0
                && frame.maxY < viewportHeight * Self.followThreshold
            if isComfortablyVisible {
                resumeFollowing()
            }
            return
        }

        // Reading only ever moves down the page; upward corrections belong to
        // explicit jumps, which would otherwise fight this at the first screen.
        guard frame.maxY > viewportHeight * Self.followThreshold else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(
                highlightIndex,
                anchor: UnitPoint(x: 0.5, y: Self.restingPosition)
            )
        }
    }

    private static let scrollSpace = "readAloudDocument"

    private static func paragraphAnchor(_ paragraph: Int) -> String {
        "paragraph-\(paragraph)"
    }

    /// Repositions after a scrub or sentence skip. The target paragraph may not
    /// be built yet — and a word inside an unbuilt row has no anchor to scroll
    /// to — so the paragraph goes first and the word is placed next runloop pass.
    private func jump(_ proxy: ScrollViewProxy, to index: Int) {
        proxy.scrollTo(
            Self.paragraphAnchor(document.paragraph(containing: index)),
            anchor: UnitPoint(x: 0.5, y: Self.restingPosition)
        )

        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(
                    index,
                    anchor: UnitPoint(x: 0.5, y: Self.restingPosition)
                )
            }
        }
    }

    private func appearance(
        for word: ReadAloudDocument.Word,
        highlightSentence: Int,
        highlightSentenceRange: Range<Int>
    ) -> ReadAloudWordView.Appearance {
        guard hasStarted else { return .init() }

        let isInActiveSentence = word.sentence == highlightSentence
        return ReadAloudWordView.Appearance(
            isCurrent: word.id == highlightIndex,
            isInActiveSentence: isInActiveSentence,
            isRead: word.id < highlightIndex && !isInActiveSentence,
            isSentenceStart: isInActiveSentence
                && word.id == highlightSentenceRange.lowerBound,
            isSentenceEnd: isInActiveSentence
                && word.id == highlightSentenceRange.upperBound - 1
        )
    }
}

/// Viewport-relative frame of the word being spoken, published by that word so
/// the reader can tell whether it still needs to scroll.
private struct ReadAloudCurrentWordFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private struct ReadAloudWordView: View {
    /// How a word is drawn. The sentence band and the spoken-word chip are
    /// separate layers, so the current word carries both.
    struct Appearance: Equatable {
        var isCurrent = false
        var isInActiveSentence = false
        var isRead = false
        /// Ends of the sentence, so its band gets rounded caps and everything
        /// between tiles flush.
        var isSentenceStart = false
        var isSentenceEnd = false
    }

    let text: String
    let appearance: Appearance
    /// Only the spoken word measures itself — one geometry reader, not one per
    /// word of the document.
    var reportsPosition = false
    let onTap: () -> Void

    @State private var isHovering = false

    private static let fontSize = 16.5
    /// The weight the spoken word is set in. Every word is laid out at this
    /// weight even when drawn lighter — see below.
    private static let heaviestWeight = Font.Weight.semibold
    private static let cornerRadius = 5.0

    var body: some View {
        ZStack {
            // Semibold glyphs are wider than regular ones, so letting the
            // highlight change a word's weight would re-wrap the paragraph
            // around it as the reading moved through. This invisible copy is
            // always set in the heaviest weight, fixing every word at its
            // widest — the visible text can then change weight freely and the
            // text never moves.
            Text(text)
                .font(DS.Fonts.ui(Self.fontSize, Self.heaviestWeight))
                .hidden()

            Text(text)
                .font(
                    DS.Fonts.ui(
                        Self.fontSize,
                        appearance.isCurrent ? Self.heaviestWeight : .regular
                    )
                )
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background {
            // Every layer is drawn inside the word's own box. Neighbouring
            // words tile edge to edge, so the sentence reads as one continuous
            // band instead of a row of overlapping pills.
            ZStack {
                if appearance.isInActiveSentence {
                    sentenceBand.fill(DS.Colors.accentSoft)
                }
                if appearance.isCurrent {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(DS.Colors.accent)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(DS.Colors.bgInset)
                }
            }
        }
        .background {
            if reportsPosition {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ReadAloudCurrentWordFrame.self,
                        value: geometry.frame(in: .named("readAloudDocument"))
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.18), value: appearance)
    }

    /// Square where the band continues into the next word, rounded where the
    /// sentence actually begins and ends.
    private var sentenceBand: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: appearance.isSentenceStart ? Self.cornerRadius : 0,
            bottomLeadingRadius: appearance.isSentenceStart ? Self.cornerRadius : 0,
            bottomTrailingRadius: appearance.isSentenceEnd ? Self.cornerRadius : 0,
            topTrailingRadius: appearance.isSentenceEnd ? Self.cornerRadius : 0
        )
    }

    private var foreground: Color {
        if appearance.isCurrent { return .white }
        if appearance.isRead { return DS.Colors.textSecondary }
        return DS.Colors.ink
    }

}

// MARK: - Player

private struct ReadAloudPlayerBar: View {
    let appState: AppState
    let isReady: Bool

    var body: some View {
        let document = appState.readAloudDocument
        let position = appState.readAloudWordIndex
        let canPlay = isReady && !document.isEmpty
            && (appState.status == .idle || appState.isReadAloudInProgress)

        HStack(spacing: 14) {
            HStack(spacing: 8) {
                DSIconButton(
                    systemImage: "backward.end.fill",
                    tint: DS.Colors.ink,
                    accessibilityLabel: "Previous sentence"
                ) {
                    appState.skipReadAloudSentence(by: -1)
                }
                .disabled(document.isEmpty)

                Button {
                    appState.toggleReadAloud()
                } label: {
                    Image(systemName: appState.isReadAloudInProgress ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle().fill(canPlay ? DS.Colors.accent : DS.Colors.toggleOff)
                        )
                        .shadow(color: DS.Colors.accentDeep.opacity(0.24), radius: 5, x: 0, y: 2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .accessibilityLabel(appState.isReadAloudInProgress ? "Pause" : "Play")

                DSIconButton(
                    systemImage: "forward.end.fill",
                    tint: DS.Colors.ink,
                    accessibilityLabel: "Next sentence"
                ) {
                    appState.skipReadAloudSentence(by: 1)
                }
                .disabled(document.isEmpty)
            }

            VStack(alignment: .leading, spacing: 8) {
                ReadAloudScrubber(
                    progress: appState.readAloudProgress,
                    isEnabled: !document.isEmpty
                ) { fraction in
                    let target = Int((Double(document.wordCount) * fraction).rounded(.down))
                    appState.seekReadAloud(toWordIndex: target)
                }

                HStack {
                    Text("word \(min(position + 1, document.wordCount)) of \(document.wordCount)")
                        .font(DS.Fonts.ui(12, .medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer(minLength: 12)
                    Text(remainingLabel(document: document, position: position))
                        .font(DS.Fonts.ui(12))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }

            DSIconButton(
                systemImage: "stop.fill",
                tint: DS.Colors.destructive,
                accessibilityLabel: "Stop"
            ) {
                appState.stopReadAloud()
            }
            .disabled(!appState.isReadAloudInProgress && !appState.isReadAloudPaused)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(DS.Colors.bgInset)
    }

    private func remainingLabel(
        document: ReadAloudDocument,
        position: Int
    ) -> String {
        guard position < document.wordCount else { return "finished" }
        return ReadAloudDocument.approximateDurationLabel(
            seconds: document.estimatedSeconds(from: position)
        ) + " left"
    }
}

/// Word-accurate scrub track. The seek is committed on release — dragging live
/// would restart speech synthesis on every pixel of travel.
private struct ReadAloudScrubber: View {
    let progress: Double
    let isEnabled: Bool
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    private let knobSize: CGFloat = 14
    private let trackHeight: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = min(max(dragFraction ?? progress, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.sliderTrackRest)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(DS.Colors.accent)
                    .frame(width: max(width * fraction, 0), height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(DS.Colors.border, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.13), radius: 3, x: 0, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(
                        x: min(max(width * fraction - knobSize / 2, 0), max(width - knobSize, 0))
                    )
            }
            .frame(height: knobSize, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, width > 0 else { return }
                        dragFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        guard isEnabled, width > 0 else { return }
                        let target = min(max(value.location.x / width, 0), 1)
                        dragFraction = nil
                        onSeek(target)
                    }
            )
            .opacity(isEnabled ? 1 : 0.5)
        }
        .frame(height: knobSize)
    }
}
