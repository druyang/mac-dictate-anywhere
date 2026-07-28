//
//  AppState.swift
//  Dictate Anywhere
//
//  Central observable state. Owns all services and orchestrates dictation flow.
//

import Foundation
import AppKit
import CoreAudio
import os
import FoundationModels

nonisolated enum ReadAloudPlaybackProgress {
    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func fraction(
        playedText: String,
        totalText: String,
        isComplete: Bool
    ) -> Double {
        fraction(
            playedWordCount: wordCount(in: playedText),
            totalWordCount: wordCount(in: totalText),
            isComplete: isComplete
        )
    }

    static func fraction(
        playedWordCount: Int,
        totalWordCount: Int,
        isComplete: Bool
    ) -> Double {
        if isComplete {
            return 1
        }
        guard totalWordCount > 0 else { return 0 }
        return min(
            max(Double(playedWordCount) / Double(totalWordCount), 0),
            0.99
        )
    }

    static func remainingText(
        in totalText: String,
        afterPlayedWordCount playedWordCount: Int
    ) -> String {
        totalText
            .split(whereSeparator: \.isWhitespace)
            .dropFirst(max(playedWordCount, 0))
            .joined(separator: " ")
    }
}

@Observable
@MainActor
final class AppState {
    // MARK: - Dictation Status

    enum DictationStatus: Equatable {
        case idle
        case recording
        case processing
        case error(String)
    }

    struct OllamaDownloadState: Equatable {
        let model: String
        let status: String
        let fractionCompleted: Double?
        let completed: Int64?
        let total: Int64?
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AppState"
    )

    var status: DictationStatus = .idle
    var currentTranscript = ""
    var lastTranscript = ""
    var selectedPage: SidebarPage = .models
    var ollamaDownloadState: OllamaDownloadState?
    var ollamaDeletingModel: String?
    var ollamaModelActionError: String?
    var ollamaModelActionsRevision = 0
    var enginePreparationError: String?
    var lastAgentRequest = ""
    var lastAgentResponse = ""
    var lastAgentError: String?
    var isAgentRequestInProgress = false
    var isSpeechOutputInProgress = false
    var readAloudText = "" {
        didSet {
            guard readAloudText != oldValue else { return }
            readAloudDocument = ReadAloudDocument(source: readAloudText)
            if !isReadAloudInProgress, !isReadAloudPaused {
                readAloudWordIndex = 0
                isReadAloudFinished = false
            }
        }
    }

    /// Word-addressable view of `readAloudText`, rebuilt on every edit. The
    /// reader renders these words and playback positions are word indices into
    /// it, so a click on a word is a seek.
    private(set) var readAloudDocument = ReadAloudDocument.empty
    /// Number of words already spoken — equivalently, the word playback resumes
    /// from.
    var readAloudWordIndex = 0
    private(set) var isReadAloudFinished = false
    /// Whether the Read Aloud page is showing its editor rather than the
    /// reader. It lives here, not in view state, because the window's warning
    /// banners appear and disappear underneath the page — that reshuffles view
    /// identity and would silently drop an in-progress edit.
    var isEditingReadAloudText = false
    var readAloudError: String?
    var isReadAloudInProgress = false
    var isReadAloudPaused = false
    var agentMemoryExchangeCount = 0
    var agentMemoryEntries: [VoiceConversationMemoryEntry] = []
    var agentMemoryStorageError: String?

    /// Static accessor for AppDelegate menu bar (avoids circular dependency)
    nonisolated(unsafe) static var lastTranscriptForMenuBar = ""

    // MARK: - Services

    let permissions = Permissions()
    let settings = Settings.shared
    let hotkeyService = HotkeyService()
    let audioMonitor = AudioMonitor()
    let volumeController = VolumeController()
    let textInserter = TextInserter()
    let overlay = OverlayWindow()
    let audioDeviceManager = AudioDeviceManager()
    let parakeetEngine = ParakeetEngine()
    let appleSpeechEngine = AppleSpeechEngine()
    let speechModelManager = SpeechModelManager()
    let speechOutputService = SpeechOutputService()
    let voiceConversationStore: VoiceConversationStore
    var appleSpeechSupportedLanguages: [SupportedLanguage] = []
    private var isShowingMigrationAlert = false

    /// Whether the app is transitioning between states (simple guard)
    private var isTransitioning = false

    /// Set when a hold-to-record key-up arrives during a transition (race condition guard)
    private var pendingHoldRelease = false

    /// True while prepareActiveEngine is running (suppresses transient "not ready" warnings)
    var isPreparingEngine = false

    /// Audio level polling loop
    private var audioLevelTask: Task<Void, Never>?

    /// App that was frontmost when dictation started (used as paste target)
    private var insertionTargetApp: NSRunningApplication?

    /// Engine pinned for the active dictation session (start -> stop/cancel).
    private var sessionEngine: TranscriptionEngine?
    private var sessionHotkeyMode: HotkeyMode?
    private var sessionHotkeyAction: HotkeyAction?
    private var agentRequestGeneration = 0
    private var agentRequestTask: Task<Void, Never>?
    private var readAloudGeneration = 0
    private var readAloudTask: Task<Void, Never>?
    private var readAloudSegmentStart = 0
    private var startupTask: Task<Void, Never>?
    private var hasStarted = false

    // MARK: - Active Engine

    var activeEngine: TranscriptionEngine {
        switch settings.engineChoice {
        case .parakeet:
            return parakeetEngine
        case .appleSpeech:
            return AppleSpeechEngine.isSupported ? appleSpeechEngine : parakeetEngine
        }
    }

    var availableEngineChoices: [TranscriptionEngineChoice] {
        TranscriptionEngineChoice.allCases
    }

    // MARK: - Initialization

    init(voiceConversationStore: VoiceConversationStore? = nil) {
        if let voiceConversationStore {
            self.voiceConversationStore = voiceConversationStore
        } else {
            do {
                self.voiceConversationStore = try VoiceConversationStore(
                    isStoredInMemoryOnly: AppDelegate.isRunningTests
                )
            } catch {
                self.voiceConversationStore = try! VoiceConversationStore(
                    isStoredInMemoryOnly: true
                )
                agentMemoryStorageError =
                    "Conversation memory could not open its local database. Changes will not persist after quitting. \(error.localizedDescription)"
            }
        }

        refreshAgentMemoryStatus(pruneToCurrentLimit: true)
        setupHotkeyCallbacks()
        setupPermissionCallbacks()
    }

    // MARK: - Hotkey Callbacks

    private func setupHotkeyCallbacks() {
        hotkeyService.onKeyDown = { [weak self] binding in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch binding.mode {
                case .holdToRecord:
                    await self.startDictation(mode: binding.mode, action: binding.action)
                case .handsFreeToggle:
                    if self.status == .recording {
                        await self.stopDictation()
                    } else {
                        await self.startDictation(mode: binding.mode, action: binding.action)
                    }
                }
            }
        }

        hotkeyService.onKeyUp = { [weak self] binding in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard binding.mode == .holdToRecord else { return }
                if self.status == .recording, !self.isTransitioning {
                    await self.stopDictation()
                } else if self.isTransitioning {
                    // Key released while startDictation() is still running;
                    // startDictation will check this flag after its transition.
                    self.pendingHoldRelease = true
                }
            }
        }

        hotkeyService.onEscape = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.cancelDictation()
            }
        }
    }

    private func setupPermissionCallbacks() {
        permissions.onAccessibilityPermissionChanged = { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.handleAccessibilityPermissionChanged(granted)
            }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        startupTask = Task { [weak self] in
            await self?.runStartupSequence()
        }
    }

    private func runStartupSequence() async {
        await permissions.check()
        updateAccessibilityIntegration(granted: permissions.accessibilityGranted, promptIfNeeded: true)
        speechModelManager.refresh()
        await prepareActiveEngine()
    }

    private func handleAccessibilityPermissionChanged(_ granted: Bool) {
        updateAccessibilityIntegration(granted: granted, promptIfNeeded: false)
    }

    private func updateAccessibilityIntegration(granted: Bool, promptIfNeeded: Bool) {
        if granted {
            permissions.stopPolling()
            if settings.hasHotkey && !hotkeyService.isMonitoring {
                hotkeyService.startMonitoring()
            }
        } else {
            hotkeyService.stopMonitoring()
            if promptIfNeeded {
                permissions.promptForAccessibility()
            }
            permissions.startPolling()
        }
    }

    // MARK: - Engine Lifecycle

    func prepareActiveEngine() async {
        logger.info("prepareActiveEngine: called, engineChoice=\(String(describing: self.settings.engineChoice), privacy: .public), status=\(String(describing: self.status), privacy: .public)")
        if case .recording = status { return }
        if case .processing = status { return }
        if case .error = status { status = .idle }

        switch settings.engineChoice {
        case .parakeet:
            // Auto-default: if the user hasn't explicitly chosen an engine and
            // a speech model is downloaded, ensure FluidAudio is selected.
            await parakeetEngine.recheckAllModelsOnDisk()
            await parakeetEngine.handleSelectedModelChange()
            let hasSpeechModel = parakeetEngine.checkAnyModelOnDisk()
            if !settings.userHasChosenEngine, hasSpeechModel {
                settings.engineChoice = .parakeet
            }
            if hasSpeechModel {
                settings.legacyAppleSpeechMigrationPending = false
            }
        case .appleSpeech:
            await refreshAppleSpeechLanguages()
            if !appleSpeechSupportedLanguages.contains(settings.appleSpeechLanguage),
               let fallback = appleSpeechSupportedLanguages.first {
                settings.appleSpeechLanguage = fallback
            }
            settings.legacyAppleSpeechMigrationPending = false
        }

        let ready = activeEngine.isReady
        logger.info("prepareActiveEngine: activeEngine.isReady=\(ready, privacy: .public), willCallPrepare=\(!ready, privacy: .public)")
        if !ready {
            // Set synchronously so the UI sees it before any await yields
            isPreparingEngine = true
            enginePreparationError = nil
            do {
                try await activeEngine.prepare()
            } catch {
                logger.error("prepareActiveEngine: prepare() failed on first attempt: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(1))
                do {
                    try await activeEngine.prepare()
                } catch {
                    logger.error("prepareActiveEngine: prepare() failed on retry: \(error.localizedDescription, privacy: .public)")
                    enginePreparationError = error.localizedDescription
                }
            }
            logger.info("prepareActiveEngine: prepare() completed, isReady=\(self.activeEngine.isReady, privacy: .public)")
        }
        isPreparingEngine = false
    }

    func handleParakeetModelSelectionChange(userInitiated: Bool) async {
        guard status == .idle else { return }
        settings.engineChoice = .parakeet
        settings.userHasChosenEngine = userInitiated
        await parakeetEngine.handleSelectedModelChange()
        await prepareActiveEngine()
    }

    func handleEngineSelectionChange(_ choice: TranscriptionEngineChoice) async {
        guard status == .idle else { return }
        guard availableEngineChoices.contains(choice) else { return }
        guard choice != .appleSpeech || AppleSpeechEngine.isSupported else { return }

        if choice != .appleSpeech {
            await appleSpeechEngine.invalidatePreparedSession()
        }
        enginePreparationError = nil
        settings.engineChoice = choice
        settings.userHasChosenEngine = true
        await prepareActiveEngine()
    }

    func handleAppleSpeechLanguageChange(_ language: SupportedLanguage) async {
        guard status == .idle, settings.engineChoice == .appleSpeech else { return }
        guard appleSpeechSupportedLanguages.contains(language) else { return }
        settings.appleSpeechLanguage = language
        await appleSpeechEngine.invalidatePreparedSession()
        await prepareActiveEngine()
    }

    private func refreshAppleSpeechLanguages() async {
        appleSpeechSupportedLanguages = await AppleSpeechEngine.supportedLanguages()
    }

    // MARK: - Ollama Model Management

    func startOllamaModelDownload(_ model: String) async {
        guard ollamaDownloadState == nil, ollamaDeletingModel == nil else { return }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }

        ollamaModelActionError = nil
        ollamaDownloadState = OllamaDownloadState(
            model: trimmedModel,
            status: "Preparing model download...",
            fractionCompleted: nil,
            completed: nil,
            total: nil
        )

        do {
            for try await progress in OllamaPostProcessingService.pullModel(
                baseURL: settings.ollamaBaseURL,
                model: trimmedModel
            ) {
                guard !Task.isCancelled else { return }
                ollamaDownloadState = OllamaDownloadState(
                    model: trimmedModel,
                    status: progress.displayStatus,
                    fractionCompleted: progress.fractionCompleted,
                    completed: progress.overallCompleted ?? progress.completed,
                    total: progress.overallTotal ?? progress.total
                )
            }

            ollamaDownloadState = nil
            ollamaModelActionError = nil
            ollamaModelActionsRevision += 1
        } catch {
            guard !Task.isCancelled else { return }
            ollamaDownloadState = nil
            ollamaModelActionError = error.localizedDescription
        }
    }

    func deleteOllamaModel(_ model: String) async {
        guard ollamaDownloadState == nil, ollamaDeletingModel == nil else { return }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }

        ollamaDeletingModel = trimmedModel
        ollamaModelActionError = nil

        do {
            try await OllamaPostProcessingService.removeModel(
                baseURL: settings.ollamaBaseURL,
                model: trimmedModel
            )
            ollamaDeletingModel = nil
            ollamaModelActionError = nil
            ollamaModelActionsRevision += 1
        } catch {
            guard !Task.isCancelled else { return }
            ollamaDeletingModel = nil
            ollamaModelActionError = error.localizedDescription
        }
    }

    // MARK: - Dictation Flow

    func startDictation(
        mode: HotkeyMode? = nil,
        action: HotkeyAction = .dictate
    ) async {
        interruptAgentSessionForNewSession()
        logger.info("startDictation: entry, status=\(String(describing: self.status), privacy: .public), isTransitioning=\(self.isTransitioning, privacy: .public), engineChoice=\(String(describing: self.settings.engineChoice), privacy: .public)")
        if case .error = status {
            status = .idle
        }
        guard status == .idle, !isTransitioning else { return }
        let engine = activeEngine
        switch settings.engineChoice {
        case .parakeet:
            if parakeetEngine.isDownloading {
                logger.warning("startDictation: selected model is still downloading")
                status = .error("\(settings.parakeetModelChoice.displayName) is still downloading. Try again when it finishes.")
                status = .idle
                return
            }

            if !(await parakeetEngine.refreshSelectedModelReadiness()) {
                await prepareActiveEngine()
            }

            guard await parakeetEngine.refreshSelectedModelReadiness(), engine.isReady else {
                logger.warning("startDictation: FluidAudio engine not ready, aborting")
                if settings.legacyAppleSpeechMigrationPending && !parakeetEngine.checkModelOnDisk() {
                    showLegacyAppleSpeechUnavailableAlert()
                }
                status = .error("\(settings.parakeetModelChoice.displayName) is not ready. Download it from Speech Model settings.")
                status = .idle
                return
            }
        case .appleSpeech:
            if !engine.isReady {
                await prepareActiveEngine()
            }
            guard engine.isReady else {
                logger.warning("startDictation: Apple Speech engine not ready, aborting")
                status = .error("Apple Speech is not ready. Open Speech Model settings to finish setup.")
                status = .idle
                return
            }
        }
        if action == .dictate {
            captureInsertionTargetApp()
        } else {
            insertionTargetApp = nil
        }

        isTransitioning = true
        pendingHoldRelease = false
        sessionEngine = engine
        sessionHotkeyMode = mode
        sessionHotkeyAction = action
        configureEndOfUtteranceHandler(for: engine)

        status = .recording
        currentTranscript = ""

        // Play start sound
        settings.playSound("Tink")

        // Resolve preferred input route up front; startup will retry with fallbacks if needed.
        let preferredDeviceID = MicrophoneHelper.effectiveDeviceID()
        let hasExplicitMicrophoneSelection = settings.selectedMicrophoneUID != nil

        // Boost mic volume if enabled
        if settings.boostMicrophoneVolumeEnabled {
            volumeController.boostMicrophoneVolume(deviceID: preferredDeviceID)
        }

        // Mute system audio if enabled
        if settings.muteSystemAudioDuringRecordingEnabled {
            volumeController.adjustForRecording()
        }

        // Start recording (must complete before showing overlay so the mic
        // is actually capturing audio when the user sees the "listening" UI)
        let startCandidates: [AudioDeviceID?] = {
            if hasExplicitMicrophoneSelection {
                return preferredDeviceID.map { [$0] } ?? []
            }
            var ids: [AudioDeviceID?] = [preferredDeviceID]
            let refreshedDefault = MicrophoneHelper.currentDefaultInputDeviceID()
            if refreshedDefault != preferredDeviceID {
                ids.append(refreshedDefault)
            }
            if !ids.contains(where: { $0 == nil }) {
                ids.append(nil)
            }
            return ids
        }()

        var lastStartError: Error? = hasExplicitMicrophoneSelection && preferredDeviceID == nil
            ? TranscriptionError.deviceSelectionFailed
            : nil
        var didStart = false
        for (index, candidateID) in startCandidates.enumerated() {
            if index > 0 {
                logger.warning(
                    "startDictation: retrying startRecording attempt \(index + 1, privacy: .public) with deviceID=\(candidateID.map { String($0) } ?? "nil", privacy: .public)"
                )
                try? await Task.sleep(for: .milliseconds(220))
            }

            do {
                try await engine.startRecording(deviceID: candidateID)
                didStart = true
                logger.info(
                    "startDictation: startRecording succeeded on attempt \(index + 1, privacy: .public), deviceID=\(candidateID.map { String($0) } ?? "nil", privacy: .public)"
                )
                break
            } catch {
                lastStartError = error
                logger.error(
                    "startDictation: startRecording attempt \(index + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        guard didStart else {
            let message = lastStartError?.localizedDescription ?? "Unknown audio startup error"
            status = .error("Failed to start recording: \(message)")
            overlay.show(state: .processing)
            overlay.hide(afterDelay: 2.0)
            insertionTargetApp = nil
            volumeController.restoreMicrophoneVolume()
            if settings.muteSystemAudioDuringRecordingEnabled {
                volumeController.restoreAfterRecording()
            }
            isTransitioning = false
            pendingHoldRelease = false
            clearEndOfUtteranceHandler(for: engine)
            sessionEngine = nil
            sessionHotkeyMode = nil
            sessionHotkeyAction = nil
            status = .idle
            return
        }

        // Show overlay only after mic is confirmed active
        overlay.show(state: .listening(level: 0, transcript: ""))

        // Start audio level polling
        startAudioLevelPolling(engine: engine)

        isTransitioning = false

        // If the user released a hold-to-record key while we were starting up, stop now.
        if pendingHoldRelease {
            pendingHoldRelease = false
            await stopDictation()
        }
    }

    func stopDictation() async {
        guard status == .recording, !isTransitioning else { return }
        isTransitioning = true

        status = .processing
        stopAudioLevelPolling()

        // Show processing overlay
        overlay.show(state: .processing)

        // Play stop sound
        settings.playSound("Pop")

        let engine = sessionEngine ?? activeEngine
        let sessionAction = sessionHotkeyAction ?? .dictate

        // Get final transcript
        let transcript = await engine.stopRecording()
        clearEndOfUtteranceHandler(for: engine)
        sessionEngine = nil
        sessionHotkeyMode = nil
        sessionHotkeyAction = nil

        // Apply filler word removal
        let cleaned = settings.removeFillerWords(from: transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        let liveFallback = settings.removeFillerWords(from: currentTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = liveFallback.count > cleaned.count ? liveFallback : cleaned

        guard !finalText.isEmpty else {
            currentTranscript = ""
            volumeController.restoreMicrophoneVolume()
            // Restore recording audio state (brief pause lets BT audio routing settle)
            if settings.muteSystemAudioDuringRecordingEnabled {
                try? await Task.sleep(for: .milliseconds(200))
                volumeController.restoreAfterRecording()
            }
            overlay.show(state: .success)
            overlay.hide(afterDelay: 0.5)
            status = .idle
            insertionTargetApp = nil
            isTransitioning = false
            return
        }

        if sessionAction == .ask {
            currentTranscript = finalText
            lastTranscript = finalText
            Self.lastTranscriptForMenuBar = finalText
            // Ask requests belong to assistant conversation memory, not
            // Dictation History.
            insertionTargetApp = nil
            await restoreRecordingAudio()
            // Recording has fully stopped. The agent request owns its own
            // cancellation state and must not keep the recording transition
            // lock held while it generates or speaks a response.
            isTransitioning = false
            await performAgentRequest(prompt: finalText)
            return
        }

        currentTranscript = finalText
        lastTranscript = finalText
        Self.lastTranscriptForMenuBar = finalText

        // Transcript post-processing
        var processedText = finalText
        logger.info(
            "postProcessing: mode=\(self.settings.transcriptPostProcessingMode.rawValue, privacy: .public), speechModel=\(self.settings.parakeetModelChoice.rawValue, privacy: .public), inputChars=\(finalText.count, privacy: .public)"
        )
        switch settings.transcriptPostProcessingMode {
        case .none:
            break
        case .fluidAudioVocabulary:
            if settings.parakeetModelChoice.usesTrueStreaming {
                logger.warning(
                    "postProcessing: FluidAudio Vocabulary is not available for true streaming model \(self.settings.parakeetModelChoice.rawValue, privacy: .public)"
                )
            }
        case .appleIntelligence:
            if !settings.aiPostProcessingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if #available(macOS 26, *) {
                    if case .available = AIPostProcessingService.availability {
                        do {
                            processedText = try await AIPostProcessingService.process(
                                text: finalText,
                                prompt: settings.aiPostProcessingPrompt,
                                vocabulary: settings.customVocabulary
                            )
                        } catch {
                            logger.error("postProcessing: Apple Intelligence failed: \(error.localizedDescription, privacy: .public)")
                        }
                    } else {
                        logger.warning("postProcessing: Apple Intelligence is not available")
                    }
                }
            } else {
                logger.info("postProcessing: Apple Intelligence skipped because prompt is empty")
            }
        case .ollama:
            do {
                processedText = try await OllamaPostProcessingService.process(
                    text: finalText,
                    baseURL: settings.ollamaBaseURL,
                    model: settings.ollamaModel,
                    reasoning: settings.ollamaReasoningSetting,
                    prompt: settings.ollamaPostProcessingPrompt,
                    vocabulary: settings.customVocabulary
                )
            } catch {
                logger.error("postProcessing: Ollama failed: \(error.localizedDescription, privacy: .public)")
            }
        case .openRouter:
            do {
                processedText = try await OpenRouterPostProcessingService.process(
                    text: finalText,
                    model: settings.openRouterModel,
                    prompt: settings.openRouterPostProcessingPrompt,
                    vocabulary: settings.customVocabulary,
                    apiKey: settings.openRouterAPIKey,
                    apiKeyEnvironmentVariable: settings.openRouterAPIKeyEnvironmentVariable
                )
            } catch {
                logger.error("postProcessing: OpenRouter failed: \(error.localizedDescription, privacy: .public)")
            }
        case .openAICompatible:
            do {
                processedText = try await OpenAICompatiblePostProcessingService.process(
                    text: finalText,
                    baseURL: settings.openAICompatibleBaseURL,
                    model: settings.openAICompatibleModel,
                    apiKey: settings.openAICompatibleAPIKey,
                    prompt: settings.openAICompatiblePostProcessingPrompt,
                    vocabulary: settings.customVocabulary
                )
            } catch {
                logger.error("postProcessing: OpenAI Compatible failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if settings.transcriptPostProcessingMode != .none,
           settings.transcriptPostProcessingMode != .fluidAudioVocabulary {
            processedText = normalizePostProcessedTranscript(processedText)
        }
        logger.info(
            "postProcessing: completed changed=\(processedText != finalText, privacy: .public), outputChars=\(processedText.count, privacy: .public)"
        )

        currentTranscript = processedText
        lastTranscript = processedText
        Self.lastTranscriptForMenuBar = processedText
        settings.addDictationHistoryEntry(processedText, for: sessionAction)

        // Insert text
        NotificationCenter.default.post(name: .dismissMenusForPaste, object: nil)
        await reactivateInsertionTargetIfNeeded()
        let result = await textInserter.insertText(processedText)
        insertionTargetApp = nil

        // Restore mic volume and recording audio state after text insertion.
        // gives Bluetooth audio routing time to settle back to playback mode.
        volumeController.restoreMicrophoneVolume()
        if settings.muteSystemAudioDuringRecordingEnabled {
            try? await Task.sleep(for: .milliseconds(200))
            volumeController.restoreAfterRecording()
        }

        switch result {
        case .success:
            overlay.show(state: .success)
        case .copiedOnly:
            overlay.show(state: .copiedOnly)
        case .failed:
            overlay.show(state: .copiedOnly)
        }

        overlay.hide(afterDelay: 1.0)
        status = .idle
        isTransitioning = false
    }

    func cancelDictation() async {
        if sessionEngine == nil, isReadAloudInProgress || isReadAloudPaused {
            stopReadAloud()
            return
        }
        if sessionEngine == nil, isAgentRequestInProgress {
            interruptAgentSessionForNewSession()
            return
        }

        guard status == .recording || status == .processing else { return }

        stopAudioLevelPolling()

        let engine = sessionEngine ?? activeEngine
        await engine.cancel()
        clearEndOfUtteranceHandler(for: engine)
        sessionEngine = nil
        sessionHotkeyMode = nil
        sessionHotkeyAction = nil

        volumeController.restoreMicrophoneVolume()
        if settings.muteSystemAudioDuringRecordingEnabled {
            try? await Task.sleep(for: .milliseconds(200))
            volumeController.restoreAfterRecording()
        }

        currentTranscript = ""
        overlay.hide(afterDelay: 0)
        status = .idle
        insertionTargetApp = nil
    }

    func askAgent(prompt: String) async {
        if isReadAloudInProgress || isReadAloudPaused {
            stopReadAloud()
        }
        interruptAgentSessionForNewSession()
        guard status == .idle, !isTransitioning else { return }
        status = .processing
        overlay.show(state: .processing)
        await performAgentRequest(prompt: prompt)
    }

    private func performAgentRequest(prompt: String) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            status = .idle
            overlay.hide(afterDelay: 0)
            return
        }

        agentRequestTask?.cancel()
        agentRequestGeneration += 1
        let generation = agentRequestGeneration
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.executeAgentRequest(
                prompt: trimmedPrompt,
                generation: generation
            )
        }
        agentRequestTask = task
        await task.value
        if generation == agentRequestGeneration {
            agentRequestTask = nil
        }
    }

    private func executeAgentRequest(prompt trimmedPrompt: String, generation: Int) async {
        guard !Task.isCancelled, generation == agentRequestGeneration else { return }
        lastAgentRequest = trimmedPrompt
        lastAgentResponse = ""
        lastAgentError = nil
        isAgentRequestInProgress = true
        status = .processing
        overlay.show(state: .processing)

        let speechConfiguration = SpeechOutputConfiguration(settings: settings)
        var streamingTextContinuation: AsyncStream<String>.Continuation?
        var streamingSpeechTask: Task<Void, Error>?

        func startStreamingSpeechIfNeeded() {
            guard streamingTextContinuation == nil else {
                return
            }
            let playback = makeStreamingSpeech(
                generation: generation,
                configuration: speechConfiguration
            )
            streamingTextContinuation = playback.continuation
            streamingSpeechTask = playback.task
        }

        if !CodexToolIntent.matches(trimmedPrompt) {
            // Prepare the model and voice session while the assistant is
            // generating its first words instead of serializing both waits.
            startStreamingSpeechIfNeeded()
        }

        do {
            var response = ""
            var completedRoute: VoiceAgentRoute?
            let conversationHistories = agentConversationHistories(for: trimmedPrompt)
            let eventStream = VoiceAgentService.streamEvents(
                to: trimmedPrompt,
                configuration: VoiceAgentService.Configuration(
                    settings: settings,
                    generalConversationHistory: conversationHistories.general,
                    codexConversationHistory: conversationHistories.codex
                )
            )
            for try await event in eventStream {
                switch event {
                case .toolStatus(let toolStatus):
                    if streamingTextContinuation != nil {
                        streamingTextContinuation?.finish()
                        streamingSpeechTask?.cancel()
                        streamingTextContinuation = nil
                        streamingSpeechTask = nil
                        speechOutputService.stop()
                    }
                    if generation == agentRequestGeneration {
                        await speakAgentToolStatus(
                            toolStatus.message,
                            generation: generation
                        )
                    }
                    await toolStatus.didFinishSpeaking()
                    try Task.checkCancellation()
                    guard generation == agentRequestGeneration else {
                        throw CancellationError()
                    }
                case .response(let partialResponse):
                    guard generation == agentRequestGeneration else {
                        throw CancellationError()
                    }
                    response = partialResponse
                    lastAgentResponse = partialResponse
                    currentTranscript = partialResponse

                    startStreamingSpeechIfNeeded()
                    streamingTextContinuation?.yield(partialResponse)
                case .completed(let route):
                    completedRoute = route
                }
            }
            try Task.checkCancellation()
            guard generation == agentRequestGeneration else { return }

            if settings.agentConversationMemoryEnabled,
               let completedRoute,
               !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saveAgentConversationExchange(
                    userMessage: trimmedPrompt,
                    assistantMessage: response,
                    route: completedRoute
                )
            }

            if let streamingSpeechTask {
                streamingTextContinuation?.finish()
                streamingTextContinuation = nil
                do {
                    try await streamingSpeechTask.value
                } catch {
                    guard !Task.isCancelled,
                          generation == agentRequestGeneration else {
                        throw CancellationError()
                    }
                    lastAgentError = "The response was generated, but \(error.localizedDescription)"
                    overlay.show(state: .error)
                }
            } else {
                let playbackTimeline = SpokenResponsePlaybackTimeline(text: response)
                do {
                    try await speechOutputService.speak(
                        response,
                        configuration: speechConfiguration,
                        onPlaybackProgress: { [weak self] progress in
                            guard let self, generation == agentRequestGeneration else { return }
                            overlay.show(
                                state: .response(
                                    text: playbackTimeline.text(at: progress),
                                    isComplete: progress >= 1
                                )
                            )
                        }
                    )
                } catch {
                    guard !Task.isCancelled, generation == agentRequestGeneration else { return }
                    lastAgentError = "The response was generated, but \(error.localizedDescription)"
                    overlay.show(state: .error)
                }
            }
        } catch is CancellationError {
            streamingTextContinuation?.finish()
            streamingSpeechTask?.cancel()
            speechOutputService.stop()
            return
        } catch {
            streamingTextContinuation?.finish()
            streamingSpeechTask?.cancel()
            speechOutputService.stop()
            guard !Task.isCancelled, generation == agentRequestGeneration else { return }

            let errorMessage = error.localizedDescription
            lastAgentError = errorMessage
            overlay.show(state: .error)
            await speakAgentError(errorMessage, generation: generation)
        }

        guard !Task.isCancelled, generation == agentRequestGeneration else { return }
        isAgentRequestInProgress = false
        overlay.hide(afterDelay: 0.6)
        status = .idle
    }

    func setAgentMemoryExchangeLimit(_ limit: Int) {
        settings.agentMemoryExchangeLimit = Settings.clampedAgentMemoryExchangeLimit(limit)
        refreshAgentMemoryStatus(pruneToCurrentLimit: true)
    }

    func clearAgentConversationMemory() {
        do {
            try voiceConversationStore.clearAll()
            agentMemoryExchangeCount = 0
            agentMemoryEntries = []
            agentMemoryStorageError = nil
        } catch {
            agentMemoryStorageError = "Conversation memory could not be cleared. \(error.localizedDescription)"
        }
    }

    func deleteAgentConversationMemory(id: UUID) {
        do {
            try voiceConversationStore.deleteExchange(id: id)
            refreshAgentMemoryStatus()
        } catch {
            agentMemoryStorageError = "Conversation memory could not be deleted. \(error.localizedDescription)"
        }
    }

    func refreshAgentMemoryStatus(pruneToCurrentLimit: Bool = false) {
        do {
            if pruneToCurrentLimit {
                try voiceConversationStore.pruneAll(to: settings.agentMemoryExchangeLimit)
            }
            agentMemoryEntries = try voiceConversationStore.allEntries()
            agentMemoryExchangeCount = agentMemoryEntries.count
            if voiceConversationStore.storeURL != nil {
                agentMemoryStorageError = nil
            }
        } catch {
            agentMemoryStorageError = "Conversation memory is unavailable. \(error.localizedDescription)"
        }
    }

    private func agentConversationHistories(
        for prompt: String
    ) -> (
        general: [VoiceConversationExchange],
        codex: [VoiceConversationExchange]
    ) {
        guard settings.agentConversationMemoryEnabled else {
            return ([], [])
        }

        do {
            let limit = settings.agentMemoryExchangeLimit
            let generalExchanges = try voiceConversationStore.exchanges(
                in: .general,
                limit: limit
            )
            let generalBudget = max(
                0,
                VoiceConversationContext.characterBudget(for: settings.agentBrainProvider)
                    - prompt.count
                    - settings.agentSystemPrompt.count
            )
            let boundedGeneralExchanges = VoiceConversationContext.newestExchanges(
                from: generalExchanges,
                fittingCharacterBudget: generalBudget
            )

            let codexExchanges: [VoiceConversationExchange]
            if settings.codexWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                codexExchanges = []
            } else {
                let storedCodexExchanges = try voiceConversationStore.exchanges(
                    in: .codex(workspacePath: settings.codexWorkspacePath),
                    limit: limit
                )
                let codexBudget = max(
                    0,
                    VoiceConversationContext.codexCharacterBudget
                        - prompt.count
                        - settings.agentSystemPrompt.count
                )
                codexExchanges = VoiceConversationContext.newestExchanges(
                    from: storedCodexExchanges,
                    fittingCharacterBudget: codexBudget
                )
            }

            return (boundedGeneralExchanges, codexExchanges)
        } catch {
            agentMemoryStorageError = "Conversation memory could not be loaded. \(error.localizedDescription)"
            return ([], [])
        }
    }

    private func saveAgentConversationExchange(
        userMessage: String,
        assistantMessage: String,
        route: VoiceAgentRoute
    ) {
        let scope: VoiceConversationScope
        let provider: AgentBrainProvider?
        let model: String

        switch route {
        case .general:
            scope = .general
            provider = settings.agentBrainProvider
            switch settings.agentBrainProvider {
            case .appleIntelligence:
                model = "system-language-model"
            case .ollama:
                model = settings.ollamaModel
            case .openRouter:
                model = settings.openRouterModel
            }
        case .codex:
            scope = .codex(workspacePath: settings.codexWorkspacePath)
            provider = nil
            model = "codex"
        }

        do {
            try voiceConversationStore.appendCompletedExchange(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                scope: scope,
                provider: provider,
                model: model,
                limit: settings.agentMemoryExchangeLimit
            )
            refreshAgentMemoryStatus()
        } catch {
            agentMemoryStorageError = "The response completed, but conversation memory could not save it. \(error.localizedDescription)"
        }
    }

    private func makeStreamingSpeech(
        generation: Int,
        configuration: SpeechOutputConfiguration
    ) -> (
        continuation: AsyncStream<String>.Continuation,
        task: Task<Void, Error>
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else {
                throw CancellationError()
            }
            try await speechOutputService.speakStreamingText(
                stream,
                configuration: configuration,
                onPlaybackText: { [weak self] text, isComplete in
                    guard let self,
                          generation == agentRequestGeneration else {
                        return
                    }
                    overlay.show(
                        state: .response(
                            text: text,
                            isComplete: isComplete
                        )
                    )
                }
            )
        }
        return (continuation, task)
    }

    private func speakAgentToolStatus(_ message: String, generation: Int) async {
        guard !message.isEmpty,
              !Task.isCancelled,
              generation == agentRequestGeneration else { return }

        currentTranscript = message
        let playbackTimeline = SpokenResponsePlaybackTimeline(text: message)
        do {
            try await speechOutputService.speak(
                message,
                configuration: SpeechOutputConfiguration(settings: settings),
                onPlaybackProgress: { [weak self] progress in
                    guard let self, generation == agentRequestGeneration else { return }
                    overlay.show(
                        state: .response(
                            text: playbackTimeline.text(at: progress),
                            isComplete: progress >= 1
                        )
                    )
                }
            )
        } catch {
            guard !Task.isCancelled, generation == agentRequestGeneration else { return }
        }

        guard !Task.isCancelled, generation == agentRequestGeneration else { return }
        currentTranscript = ""
        overlay.show(state: .processing)
    }

    private func interruptAgentSessionForNewSession() {
        guard isAgentRequestInProgress || agentRequestTask != nil else { return }

        agentRequestGeneration += 1
        agentRequestTask?.cancel()
        agentRequestTask = nil
        speechOutputService.stop()
        isAgentRequestInProgress = false
        currentTranscript = ""
        overlay.hide(afterDelay: 0)
        status = .idle
    }

    private func speakAgentError(_ message: String, generation: Int) async {
        guard generation == agentRequestGeneration else { return }
        let spokenMessage = SpokenResponseFormatter.errorText(from: message)
        guard !spokenMessage.isEmpty else { return }

        let configuration = SpeechOutputConfiguration(settings: settings)
        guard configuration.isReady else { return }

        // If error speech itself fails, keep the original visible error and
        // avoid recursively trying the same unavailable speech provider.
        try? await speechOutputService.speak(
            spokenMessage,
            configuration: configuration
        )
    }

    func downloadSpeechModel(_ model: SpeechSynthesisModel) async {
        guard status == .idle, model.isLocal else { return }
        do {
            try await speechModelManager.download(
                model,
                supertonicVoice: settings.supertonicVoice
            )
        } catch {
            speechModelManager.errorMessage = error.localizedDescription
        }
    }

    func deleteSpeechModel(_ model: SpeechSynthesisModel) async {
        guard status == .idle, model.isLocal else { return }
        await speechOutputService.unload(model)
        do {
            try speechModelManager.delete(model)
        } catch {
            speechModelManager.errorMessage = error.localizedDescription
        }
    }

    func previewSpeechOutput() async {
        guard status == .idle else { return }
        speechModelManager.errorMessage = nil
        isSpeechOutputInProgress = true
        status = .processing
        defer {
            isSpeechOutputInProgress = false
            status = .idle
        }

        do {
            try await speechOutputService.speak(
                "This is how Dictate Anywhere will sound when it answers you.",
                configuration: SpeechOutputConfiguration(settings: settings)
            )
        } catch {
            speechModelManager.errorMessage = error.localizedDescription
        }
    }

    /// Fraction of the document already spoken. Never reports a full 1 until
    /// playback actually finishes, so a nearly-done reading can't look complete.
    var readAloudProgress: Double {
        if isReadAloudFinished { return 1 }
        guard readAloudDocument.wordCount > 0 else { return 0 }
        let fraction = Double(readAloudWordIndex)
            / Double(readAloudDocument.wordCount)
        return min(max(fraction, 0), 0.99)
    }

    /// Word the reader highlights. While audio is playing the last word handed
    /// to the player is the one being heard; when idle or paused the highlight
    /// sits on the word playback would resume from.
    var readAloudHighlightIndex: Int {
        guard !readAloudDocument.isEmpty else { return 0 }
        if isReadAloudInProgress {
            return readAloudDocument.clampedWordIndex(
                max(readAloudWordIndex - 1, readAloudSegmentStart)
            )
        }
        return readAloudDocument.clampedWordIndex(readAloudWordIndex)
    }

    func startReadAloud(fromWordIndex wordIndex: Int = 0) {
        guard !readAloudDocument.isEmpty else {
            readAloudError = "Paste some text before starting playback."
            return
        }
        guard status == .idle else { return }

        let configuration = SpeechOutputConfiguration(settings: settings)
        guard configuration.isReady else {
            readAloudError =
                "Set up \(configuration.model.displayName) on the Speech Model page first."
            return
        }

        let start = readAloudDocument.clampedWordIndex(wordIndex)
        readAloudWordIndex = start
        isReadAloudFinished = false
        readAloudError = nil
        isReadAloudPaused = false
        startReadAloudSegment(from: start, configuration: configuration)
    }

    /// Moves the reading position. Playback that is already running continues
    /// from the new word; a paused or idle reader just moves its highlight.
    func seekReadAloud(toWordIndex wordIndex: Int) {
        guard !readAloudDocument.isEmpty else { return }
        let target = readAloudDocument.clampedWordIndex(wordIndex)
        let wasPlaying = isReadAloudInProgress

        if wasPlaying {
            cancelReadAloudPlayback()
        }
        readAloudWordIndex = target
        isReadAloudFinished = false
        readAloudError = nil

        guard wasPlaying else { return }
        let configuration = SpeechOutputConfiguration(settings: settings)
        guard configuration.isReady else {
            isReadAloudPaused = true
            readAloudError =
                "Set up \(configuration.model.displayName) on the Speech Model page first."
            return
        }
        startReadAloudSegment(from: target, configuration: configuration)
    }

    /// Jumps whole sentences, the way a track skip works: backwards restarts
    /// the current sentence unless it only just began.
    func skipReadAloudSentence(by delta: Int) {
        guard !readAloudDocument.isEmpty else { return }
        let from = readAloudHighlightIndex
        let target = delta < 0
            ? readAloudDocument.previousSentenceStart(from: from)
            : readAloudDocument.nextSentenceStart(from: from)

        guard target < readAloudDocument.wordCount else {
            // Skipping past the last sentence ends the reading.
            stopReadAloud()
            readAloudWordIndex = readAloudDocument.wordCount
            isReadAloudFinished = true
            return
        }
        seekReadAloud(toWordIndex: target)
    }

    func toggleReadAloud() {
        if isReadAloudInProgress {
            pauseReadAloud()
        } else if isReadAloudPaused {
            resumeReadAloud()
        } else {
            startReadAloud(
                fromWordIndex: isReadAloudFinished ? 0 : readAloudWordIndex
            )
        }
    }

    func pauseReadAloud() {
        guard isReadAloudInProgress else { return }

        cancelReadAloudPlayback()
        isReadAloudPaused = true
    }

    func resumeReadAloud() {
        guard isReadAloudPaused, status == .idle else { return }

        guard readAloudWordIndex < readAloudDocument.wordCount else {
            isReadAloudPaused = false
            isReadAloudFinished = true
            return
        }

        let configuration = SpeechOutputConfiguration(settings: settings)
        guard configuration.isReady else {
            readAloudError =
                "Set up \(configuration.model.displayName) on the Speech Model page first."
            return
        }

        readAloudError = nil
        isReadAloudPaused = false
        startReadAloudSegment(from: readAloudWordIndex, configuration: configuration)
    }

    func stopReadAloud() {
        guard isReadAloudInProgress
            || isReadAloudPaused
            || readAloudTask != nil else {
            return
        }

        cancelReadAloudPlayback()
        isReadAloudPaused = false
        readAloudWordIndex = 0
        readAloudSegmentStart = 0
        isReadAloudFinished = false
    }

    func clearReadAloudText() {
        guard !isReadAloudInProgress, !isReadAloudPaused else { return }
        readAloudText = ""
        isEditingReadAloudText = false
        readAloudWordIndex = 0
        isReadAloudFinished = false
        readAloudError = nil
    }

    /// Tears down the running segment without touching the reading position, so
    /// pause, seek and stop can each decide what the position should become.
    private func cancelReadAloudPlayback() {
        readAloudGeneration += 1
        readAloudTask?.cancel()
        readAloudTask = nil
        speechOutputService.stop()
        isReadAloudInProgress = false
        isSpeechOutputInProgress = false
        if status == .processing {
            status = .idle
        }
    }

    private func startReadAloudSegment(
        from wordIndex: Int,
        configuration: SpeechOutputConfiguration
    ) {
        let segmentText = readAloudDocument.spokenText(from: wordIndex)
        guard !segmentText.isEmpty else {
            isReadAloudFinished = true
            return
        }

        readAloudTask?.cancel()
        readAloudGeneration += 1
        let generation = readAloudGeneration
        readAloudSegmentStart = wordIndex
        isReadAloudInProgress = true
        isSpeechOutputInProgress = true
        status = .processing

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performReadAloud(
                segmentText,
                priorPlayedWordCount: wordIndex,
                configuration: configuration,
                generation: generation
            )
        }
        readAloudTask = task
    }

    private func performReadAloud(
        _ segmentText: String,
        priorPlayedWordCount: Int,
        configuration: SpeechOutputConfiguration,
        generation: Int
    ) async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.yield(segmentText)
        continuation.finish()

        var reachedEnd = false

        do {
            try await speechOutputService.speakStreamingText(
                stream,
                configuration: configuration,
                onPlaybackText: { [weak self] playedText, isComplete in
                    guard let self,
                          generation == readAloudGeneration else {
                        return
                    }
                    let segmentPlayedWordCount =
                        ReadAloudPlaybackProgress.wordCount(in: playedText)
                    // Within a segment the position only moves forward; a
                    // regression means a stale progress callback, and letting it
                    // through would send the highlight back up the page.
                    readAloudWordIndex = max(
                        readAloudWordIndex,
                        min(
                            priorPlayedWordCount + segmentPlayedWordCount,
                            readAloudDocument.wordCount
                        )
                    )
                    if isComplete {
                        readAloudWordIndex = readAloudDocument.wordCount
                        isReadAloudFinished = true
                    }
                }
            )
            reachedEnd = true
        } catch is CancellationError {
            // Stopping playback is an expected user action.
        } catch {
            guard generation == readAloudGeneration else { return }
            readAloudError = error.localizedDescription
        }

        guard generation == readAloudGeneration else { return }
        if reachedEnd {
            // The engine may finish without a final progress callback; the
            // reader must still land on the end of the document.
            readAloudWordIndex = readAloudDocument.wordCount
            isReadAloudFinished = true
        }
        readAloudTask = nil
        isReadAloudInProgress = false
        isReadAloudPaused = false
        isSpeechOutputInProgress = false
        if status == .processing {
            status = .idle
        }
    }

    private func restoreRecordingAudio() async {
        volumeController.restoreMicrophoneVolume()
        if settings.muteSystemAudioDuringRecordingEnabled {
            try? await Task.sleep(for: .milliseconds(200))
            volumeController.restoreAfterRecording()
        }
    }

    // MARK: - Audio Level Polling

    private func captureInsertionTargetApp() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != currentPID else {
            insertionTargetApp = nil
            return
        }
        insertionTargetApp = frontmost
    }

    private func reactivateInsertionTargetIfNeeded() async {
        guard let app = insertionTargetApp, !app.isTerminated else { return }
        if app.activate() {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func startAudioLevelPolling(engine: TranscriptionEngine) {
        audioLevelTask = Task { [weak self] in
            var displayTranscript = ""
            var transcriptPollTick = 0
            var lastTranscriptLength = 0
            while !Task.isCancelled {
                guard let self, self.status == .recording else { break }

                // Pull level samples from the lock-protected buffer (thread-safe)
                let samples = engine.levelSamples(count: 1600)
                self.audioMonitor.update(samples: samples)
                let level = self.audioMonitor.smoothedLevel
                transcriptPollTick += 1

                // Only copy transcript when it has actually changed
                if transcriptPollTick >= 6 {
                    transcriptPollTick = 0
                    let transcript = engine.currentTranscript
                    if transcript.count != lastTranscriptLength {
                        lastTranscriptLength = transcript.count
                        displayTranscript = transcript
                        self.currentTranscript = displayTranscript
                    }
                }

                self.overlay.show(state: .listening(level: level, transcript: displayTranscript))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopAudioLevelPolling() {
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioMonitor.reset()
    }

    private func configureEndOfUtteranceHandler(for engine: TranscriptionEngine) {
        guard let parakeet = engine as? ParakeetEngine else { return }
        parakeet.endOfUtteranceHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.settings.autoStopAfterSpeechEndsEnabled else { return }
                guard self.settings.parakeetModelChoice.supportsEndOfUtterance else { return }
                guard self.sessionHotkeyMode == .handsFreeToggle else { return }
                guard self.status == .recording, !self.isTransitioning else { return }
                await self.stopDictation()
            }
        }
    }

    private func clearEndOfUtteranceHandler(for engine: TranscriptionEngine) {
        (engine as? ParakeetEngine)?.endOfUtteranceHandler = nil
    }

    private func showLegacyAppleSpeechUnavailableAlert() {
        guard !isShowingMigrationAlert else { return }
        isShowingMigrationAlert = true
        defer { isShowingMigrationAlert = false }

        let restorePolicy = settings.appAppearanceMode.activationPolicy
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            NSApp.setActivationPolicy(restorePolicy)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if AppleSpeechEngine.isOperatingSystemSupported {
            alert.messageText = "Apple Speech Isn’t Available on This Mac"
            alert.informativeText = """
            Dictate Anywhere has switched to FluidAudio. Download a FluidAudio speech model to \
            continue dictating.
            """
        } else {
            alert.messageText = "Apple Speech Requires macOS 26"
            alert.informativeText = """
            \(AppleSpeechEngine.operatingSystemDisplayName) does not support Apple Speech. Dictate \
            Anywhere has switched to FluidAudio. Download a FluidAudio speech model to continue dictating.
            """
        }
        alert.addButton(withTitle: "Open Speech Model")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        selectedPage = .models
        NotificationCenter.default.post(name: .requestShowMainWindow, object: nil)
    }
}

// MARK: - Audio Device Manager

@Observable
final class AudioDeviceManager {
    var availableInputDevices: [(uid: String, name: String)] = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refreshDevices()
        installDeviceChangeListener()
    }

    deinit {
        removeDeviceChangeListener()
    }

    func refreshDevices() {
        availableInputDevices = Self.enumerateInputDevices()
    }

    // MARK: - Device Enumeration

    static func enumerateInputDevices() -> [(uid: String, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        var result: [(uid: String, name: String)] = []
        for id in deviceIDs {
            guard isPhysicalDevice(deviceID: id),
                  hasInputChannels(deviceID: id),
                  let uid = deviceUID(for: id),
                  let name = deviceName(for: id) else { continue }
            result.append((uid: uid, name: name))
        }
        return result
    }

    private static func isPhysicalDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType) == noErr else {
            return false
        }
        // Block aggregate devices (e.g. CADefaultDeviceAggregate)
        if transportType == kAudioDeviceTransportTypeAggregate {
            return false
        }
        // Allow all non-virtual transports (built-in, USB, Bluetooth, etc.)
        if transportType != kAudioDeviceTransportTypeVirtual {
            return true
        }
        // Virtual transport: allow Continuity devices (iPhone/iPad), block the rest
        guard let name = deviceName(for: deviceID) else { return false }
        return name.contains("iPhone") || name.contains("iPad")
    }

    private static func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer) == noErr else {
            return false
        }
        let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
              let result = uid?.takeUnretainedValue() else { return nil }
        return result as String
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let result = name?.takeUnretainedValue() else { return nil }
        return result as String
    }

    // MARK: - Device Change Listener

    private func installDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.refreshDevices()
            }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        listenerBlock = nil
    }
}

// MARK: - Microphone Helper

enum MicrophoneHelper {
    static func effectiveDeviceID() -> AudioDeviceID? {
        guard let uid = Settings.shared.selectedMicrophoneUID else {
            return currentDefaultInputDeviceID()
        }
        return deviceID(forUID: uid)
    }

    static func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != 0, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        for id in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceUID: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &size, &deviceUID) == noErr,
               let uidValue = deviceUID?.takeUnretainedValue(),
               (uidValue as String) == uid {
                return id
            }
        }
        return nil
    }
}
