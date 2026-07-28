//
//  SpeechOutputService.swift
//  Dictate Anywhere
//
//  Local FluidAudio and OpenRouter cloud text-to-speech playback.
//

import AVFoundation
import Foundation
import FluidAudio

private struct StreamingPlaybackTeardown: @unchecked Sendable {
    let engine: AVAudioEngine?
    let player: AVAudioPlayerNode?

    func run() {
        player?.stop()
        engine?.stop()
        engine?.reset()
    }
}

private struct IndexedStreamingSpeechPhrase: Sendable {
    let index: Int
    let text: String
}

private struct EncodedStreamingSpeechPhrase: Sendable {
    let index: Int
    let text: String
    let audio: Data
}

actor StreamingSynthesisLookaheadGate {
    private let maximumOutstandingChunks: Int
    private var outstandingChunks = 0

    init(maximumOutstandingChunks: Int) {
        self.maximumOutstandingChunks = max(maximumOutstandingChunks, 1)
    }

    func acquire() async throws {
        while outstandingChunks >= maximumOutstandingChunks {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        outstandingChunks += 1
    }

    func release() {
        outstandingChunks = max(outstandingChunks - 1, 0)
    }
}

struct SpeechOutputConfiguration: Sendable {
    let model: SpeechSynthesisModel
    let supertonicVoice: SupertonicVoiceChoice
    let pocketVoice: PocketVoiceChoice
    let styleTTS2ReferenceAudioPath: String
    let language: SpeechOutputLanguage
    let openRouterModel: String
    let openRouterVoice: String
    let openRouterAPIKey: String
    let openRouterAPIKeyEnvironmentVariable: String

    init(settings: Settings) {
        model = settings.speechSynthesisModel
        supertonicVoice = settings.supertonicVoice
        pocketVoice = settings.pocketVoice
        styleTTS2ReferenceAudioPath = settings.styleTTS2ReferenceAudioPath
        language = settings.speechOutputLanguage
        openRouterModel = settings.openRouterSpeechModel
        openRouterVoice = settings.openRouterSpeechVoice
        openRouterAPIKey = settings.openRouterAPIKey
        openRouterAPIKeyEnvironmentVariable = settings.openRouterAPIKeyEnvironmentVariable
    }

    var isReady: Bool {
        switch model {
        case .openRouter:
            return OpenRouterSpeechService.isConfigured(
                model: openRouterModel,
                voice: openRouterVoice,
                apiKey: openRouterAPIKey,
                apiKeyEnvironmentVariable: openRouterAPIKeyEnvironmentVariable
            )
        case .styleTTS2:
            return SpeechModelManager.isDownloaded(model)
                && styleTTS2ReferenceAudioURL != nil
        case .supertonic3, .kokoroAne, .pocketTTS:
            return SpeechModelManager.isDownloaded(model)
        }
    }

    var styleTTS2ReferenceAudioURL: URL? {
        let trimmedPath = styleTTS2ReferenceAudioPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedPath.isEmpty,
              FileManager.default.fileExists(atPath: trimmedPath) else {
            return nil
        }
        return URL(fileURLWithPath: trimmedPath)
    }
}

@MainActor
final class SpeechOutputService {
    private static let pocketStreamingStartupFrameCount = 1

    private var supertonicManager: Supertonic3Manager?
    private var kokoroManager: KokoroAneManager?
    private var pocketManager: PocketTtsManager?
    private var styleTTS2Manager: StyleTTS2Manager?
    private var player: AVAudioPlayer?
    private var streamingEngine: AVAudioEngine?
    private var streamingPlayer: AVAudioPlayerNode?
    private var streamingSynthesisTask: Task<Void, Never>?
    private var pocketStreamingSession: PocketTtsSession?
    private var requestGeneration = 0
    private let streamingTeardownQueue = DispatchQueue(
        label: "com.dictate-anywhere.speech-output-teardown",
        qos: .default
    )

    func speak(
        _ text: String,
        configuration: SpeechOutputConfiguration,
        onPlaybackProgress: ((Double) -> Void)? = nil
    ) async throws {
        requestGeneration += 1
        let generation = requestGeneration
        stopPlayer()

        let spokenText = SpokenResponseFormatter.plainText(from: text)
        guard !spokenText.isEmpty else { return }
        guard configuration.model == .openRouter
            || SpeechModelManager.isDownloaded(configuration.model) else {
            throw SpeechModelError.modelNotDownloaded(configuration.model)
        }

        if configuration.model == .pocketTTS {
            let manager = try await pocketTtsManager(configuration: configuration)
            try await playPocketStreaming(
                spokenText,
                manager: manager,
                voice: configuration.pocketVoice.rawValue,
                generation: generation,
                onProgress: onPlaybackProgress
            )
            return
        }

        let wavData = try await synthesize(
            spokenText,
            configuration: configuration
        )
        try Task.checkCancellation()
        guard generation == requestGeneration else {
            throw CancellationError()
        }
        try await play(
            wavData,
            generation: generation,
            onProgress: onPlaybackProgress
        )
    }

    func speakStreamingText(
        _ cumulativeTextSnapshots: AsyncStream<String>,
        configuration: SpeechOutputConfiguration,
        onPlaybackText: @escaping (String, Bool) -> Void
    ) async throws {
        if configuration.model == .pocketTTS {
            try await speakPocketStreamingText(
                cumulativeTextSnapshots,
                configuration: configuration,
                onPlaybackText: onPlaybackText
            )
        } else {
            try await speakBufferedStreamingText(
                cumulativeTextSnapshots,
                configuration: configuration,
                onPlaybackText: onPlaybackText
            )
        }
    }

    func speakPocketStreamingText(
        _ cumulativeTextSnapshots: AsyncStream<String>,
        configuration: SpeechOutputConfiguration,
        onPlaybackText: @escaping (String, Bool) -> Void
    ) async throws {
        requestGeneration += 1
        let generation = requestGeneration
        stopPlayer()

        guard configuration.model == .pocketTTS else {
            throw SpeechPlaybackError.couldNotPrepare
        }
        guard SpeechModelManager.isDownloaded(.pocketTTS) else {
            throw SpeechModelError.modelNotDownloaded(.pocketTTS)
        }

        let manager = try await pocketTtsManager(configuration: configuration)
        try Task.checkCancellation()
        guard generation == requestGeneration else {
            throw CancellationError()
        }

        let session = try await manager.makeSession(
            voice: configuration.pocketVoice.rawValue
        )
        try Task.checkCancellation()
        guard generation == requestGeneration else {
            await session.cancel()
            throw CancellationError()
        }
        pocketStreamingSession = session

        let phraseState = StreamingPhrasePlaybackState()
        let feederTask = Task { @MainActor in
            var accumulator = StreamingSpeechPhraseAccumulator()
            for await snapshot in cumulativeTextSnapshots {
                guard !Task.isCancelled,
                      generation == self.requestGeneration else {
                    await session.cancel()
                    return
                }
                let spokenSnapshot = SpokenResponseFormatter.plainText(from: snapshot)
                for phrase in accumulator.ingest(spokenSnapshot) {
                    let utteranceIndex = phraseState.register(phrase)
                    precondition(
                        utteranceIndex >= 0,
                        "PocketTTS utterance indexes must be non-negative."
                    )
                    session.enqueue(phrase)
                }
            }

            guard !Task.isCancelled,
                  generation == self.requestGeneration else {
                await session.cancel()
                return
            }
            for phrase in accumulator.finish() {
                _ = phraseState.register(phrase)
                session.enqueue(phrase)
            }
            session.finish()
        }

        do {
            try await playPocketFrames(
                session.frames,
                generation: generation,
                estimatedTotalSamples: 0,
                onProgress: nil,
                onFrameScheduled: { frame in
                    guard let utteranceIndex = frame.utteranceIndex else { return }
                    phraseState.didSchedule(
                        utteranceIndex: utteranceIndex,
                        sampleCount: Int64(frame.samples.count)
                    )
                },
                onFramePlayed: { [weak self] frame in
                    guard let utteranceIndex = frame.utteranceIndex,
                          let spokenText = phraseState.playbackText(
                              utteranceIndex: utteranceIndex,
                              sampleCount: Int64(frame.samples.count)
                          ) else {
                        return
                    }
                    Task { @MainActor [weak self] in
                        guard let self,
                              generation == self.requestGeneration else {
                            return
                        }
                        onPlaybackText(spokenText, false)
                    }
                },
                onSynthesisFinished: {
                    phraseState.didFinishGeneration()
                }
            )
            await feederTask.value
            try Task.checkCancellation()
            guard generation == requestGeneration else {
                throw CancellationError()
            }
            onPlaybackText(phraseState.finalText, true)
            if pocketStreamingSession === session {
                pocketStreamingSession = nil
            }
        } catch {
            feederTask.cancel()
            await session.cancel()
            if pocketStreamingSession === session {
                pocketStreamingSession = nil
            }
            throw error
        }
    }

    private func speakBufferedStreamingText(
        _ cumulativeTextSnapshots: AsyncStream<String>,
        configuration: SpeechOutputConfiguration,
        onPlaybackText: @escaping (String, Bool) -> Void
    ) async throws {
        requestGeneration += 1
        let generation = requestGeneration
        stopPlayer()

        guard configuration.model != .pocketTTS else {
            throw SpeechPlaybackError.couldNotPrepare
        }
        guard configuration.model == .openRouter
            || SpeechModelManager.isDownloaded(configuration.model) else {
            throw SpeechModelError.modelNotDownloaded(configuration.model)
        }

        let phrases = Self.streamingPhrases(
            from: cumulativeTextSnapshots,
            coalesceForOpenRouter: configuration.model == .openRouter
        )
        let lookaheadGate = configuration.model == .openRouter
            ? StreamingSynthesisLookaheadGate(maximumOutstandingChunks: 2)
            : nil
        let synthesizedPhrases = makeSynthesizedPhraseStream(
            phrases,
            configuration: configuration,
            generation: generation,
            lookaheadGate: lookaheadGate
        )
        try await playBufferedPhrases(
            synthesizedPhrases,
            generation: generation,
            lookaheadGate: lookaheadGate,
            onPlaybackText: onPlaybackText
        )
    }

    private static func streamingPhrases(
        from cumulativeTextSnapshots: AsyncStream<String>,
        coalesceForOpenRouter: Bool
    ) -> AsyncStream<IndexedStreamingSpeechPhrase> {
        AsyncStream { continuation in
            let task = Task {
                var accumulator = StreamingSpeechPhraseAccumulator()
                var openRouterAccumulator = OpenRouterSpeechChunkAccumulator()
                var nextIndex = 0

                for await snapshot in cumulativeTextSnapshots {
                    try? Task.checkCancellation()
                    guard !Task.isCancelled else { break }
                    let spokenSnapshot = SpokenResponseFormatter.plainText(from: snapshot)
                    for phrase in accumulator.ingest(spokenSnapshot) {
                        let chunks = coalesceForOpenRouter
                            ? openRouterAccumulator.ingest(phrase)
                            : [phrase]
                        for chunk in chunks {
                            continuation.yield(
                                IndexedStreamingSpeechPhrase(
                                    index: nextIndex,
                                    text: chunk
                                )
                            )
                            nextIndex += 1
                        }
                    }
                }

                if !Task.isCancelled {
                    for phrase in accumulator.finish() {
                        let chunks = coalesceForOpenRouter
                            ? openRouterAccumulator.ingest(phrase)
                            : [phrase]
                        for chunk in chunks {
                            continuation.yield(
                                IndexedStreamingSpeechPhrase(
                                    index: nextIndex,
                                    text: chunk
                                )
                            )
                            nextIndex += 1
                        }
                    }
                    if coalesceForOpenRouter {
                        for chunk in openRouterAccumulator.finish() {
                            continuation.yield(
                                IndexedStreamingSpeechPhrase(
                                    index: nextIndex,
                                    text: chunk
                                )
                            )
                            nextIndex += 1
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func makeSynthesizedPhraseStream(
        _ phrases: AsyncStream<IndexedStreamingSpeechPhrase>,
        configuration: SpeechOutputConfiguration,
        generation: Int,
        lookaheadGate: StreamingSynthesisLookaheadGate?
    ) -> AsyncThrowingStream<EncodedStreamingSpeechPhrase, Error> {
        AsyncThrowingStream { continuation in
            streamingSynthesisTask?.cancel()
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                defer {
                    if generation == self.requestGeneration {
                        self.streamingSynthesisTask = nil
                    }
                }

                do {
                    try await self.prepareForSynthesis(configuration: configuration)
                    try Task.checkCancellation()
                    guard generation == self.requestGeneration else {
                        throw CancellationError()
                    }

                    for await phrase in phrases {
                        try Task.checkCancellation()
                        guard generation == self.requestGeneration else {
                            throw CancellationError()
                        }
                        try await lookaheadGate?.acquire()
                        let audio = try await self.synthesize(
                            phrase.text,
                            configuration: configuration
                        )
                        continuation.yield(
                            EncodedStreamingSpeechPhrase(
                                index: phrase.index,
                                text: phrase.text,
                                audio: audio
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            streamingSynthesisTask = task
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func prepareForSynthesis(
        configuration: SpeechOutputConfiguration
    ) async throws {
        switch configuration.model {
        case .supertonic3:
            if supertonicManager == nil {
                let created = Supertonic3Manager()
                try await created.initialize()
                supertonicManager = created
            }
        case .kokoroAne:
            if kokoroManager == nil {
                let created = KokoroAneManager(
                    defaultVoice: KokoroAneConstants.defaultVoice
                )
                try await created.initialize()
                kokoroManager = created
            }
        case .pocketTTS:
            _ = try await pocketTtsManager(configuration: configuration)
        case .styleTTS2:
            _ = try await styleTTS2ManagerInstance()
        case .openRouter:
            break
        }
    }

    private func playBufferedPhrases(
        _ phrases: AsyncThrowingStream<EncodedStreamingSpeechPhrase, Error>,
        generation: Int,
        lookaheadGate: StreamingSynthesisLookaheadGate?,
        onPlaybackText: @escaping (String, Bool) -> Void
    ) async throws {
        let playbackState = PocketStreamingPlaybackState()
        let phraseState = StreamingPhrasePlaybackState()
        var engine: AVAudioEngine?
        var streamingPlayer: AVAudioPlayerNode?
        var playbackFormat: AVAudioFormat?
        var playbackStarted = false

        let completionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      generation == self.requestGeneration else {
                    return
                }
                if playbackState.snapshot(estimatedTotalSamples: 0).isComplete {
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        do {
            for try await phrase in phrases {
                try Task.checkCancellation()
                guard generation == requestGeneration else {
                    throw CancellationError()
                }

                let buffer = try decodeSpeechAudioData(phrase.audio)
                guard buffer.frameLength > 0 else {
                    throw SpeechPlaybackError.couldNotPrepare
                }

                if engine == nil {
                    let createdEngine = AVAudioEngine()
                    let createdPlayer = AVAudioPlayerNode()
                    createdEngine.attach(createdPlayer)
                    createdEngine.connect(
                        createdPlayer,
                        to: createdEngine.mainMixerNode,
                        format: buffer.format
                    )
                    createdEngine.prepare()
                    do {
                        try createdEngine.start()
                    } catch {
                        throw SpeechPlaybackError.couldNotStart
                    }
                    engine = createdEngine
                    streamingPlayer = createdPlayer
                    playbackFormat = buffer.format
                    self.streamingEngine = createdEngine
                    self.streamingPlayer = createdPlayer
                }

                guard let streamingPlayer,
                      let playbackFormat,
                      audioFormatsMatch(buffer.format, playbackFormat) else {
                    throw SpeechPlaybackError.couldNotPrepare
                }

                let utteranceIndex = phraseState.register(phrase.text)
                guard utteranceIndex == phrase.index else {
                    throw SpeechPlaybackError.couldNotPrepare
                }

                let slices = try speechPCMBufferSlices(buffer)
                for (sliceIndex, slice) in slices.enumerated() {
                    let sampleCount = Int64(slice.frameLength)
                    let isLastSlice = sliceIndex == slices.indices.last
                    playbackState.didSchedule(sampleCount: sampleCount)
                    phraseState.didSchedule(
                        utteranceIndex: utteranceIndex,
                        sampleCount: sampleCount
                    )
                    streamingPlayer.scheduleBuffer(
                        slice,
                        completionCallbackType: .dataPlayedBack
                    ) { [weak self] _ in
                        playbackState.didPlay(sampleCount: sampleCount)
                        if isLastSlice, let lookaheadGate {
                            Task {
                                await lookaheadGate.release()
                            }
                        }
                        guard let spokenText = phraseState.playbackText(
                            utteranceIndex: utteranceIndex,
                            sampleCount: sampleCount
                        ) else {
                            return
                        }
                        Task { @MainActor [weak self] in
                            guard let self,
                                  generation == self.requestGeneration else {
                                return
                            }
                            onPlaybackText(spokenText, false)
                        }
                    }
                }
                phraseState.didFinishGeneration(
                    utteranceIndex: utteranceIndex
                )

                if !playbackStarted {
                    streamingPlayer.play()
                    guard streamingPlayer.isPlaying else {
                        throw SpeechPlaybackError.couldNotStart
                    }
                    playbackStarted = true
                }
            }

            guard let engine,
                  let streamingPlayer,
                  playbackState.hasScheduledAudio else {
                throw SpeechPlaybackError.couldNotPrepare
            }

            playbackState.didFinishSynthesis()
            await completionTask.value
            try Task.checkCancellation()
            guard generation == requestGeneration else {
                throw CancellationError()
            }
            onPlaybackText(phraseState.finalText, true)
            finishStreamingPlayback(engine: engine, player: streamingPlayer)
        } catch {
            completionTask.cancel()
            if let engine, let streamingPlayer {
                finishStreamingPlayback(engine: engine, player: streamingPlayer)
            }
            throw error
        }
    }

    func stop() {
        requestGeneration += 1
        stopPlayer()
    }

    private func stopPlayer() {
        streamingSynthesisTask?.cancel()
        streamingSynthesisTask = nil

        player?.stop()
        player = nil

        let engine = streamingEngine
        let streamingPlayer = streamingPlayer
        self.streamingPlayer = nil
        streamingEngine = nil
        enqueueStreamingTeardown(engine: engine, player: streamingPlayer)

        if let pocketStreamingSession {
            self.pocketStreamingSession = nil
            Task {
                await pocketStreamingSession.cancel()
            }
        }
    }

    func unload(_ model: SpeechSynthesisModel) async {
        stop()
        switch model {
        case .supertonic3:
            if let supertonicManager {
                await supertonicManager.cleanup()
            }
            supertonicManager = nil
        case .kokoroAne:
            if let kokoroManager {
                await kokoroManager.cleanup()
            }
            kokoroManager = nil
        case .pocketTTS:
            if let pocketManager {
                await pocketManager.cleanup()
            }
            pocketManager = nil
        case .styleTTS2:
            if let styleTTS2Manager {
                await styleTTS2Manager.cleanup()
            }
            styleTTS2Manager = nil
        case .openRouter:
            break
        }
    }

    private func synthesize(
        _ text: String,
        configuration: SpeechOutputConfiguration
    ) async throws -> Data {
        try Task.checkCancellation()
        switch configuration.model {
        case .supertonic3:
            let manager: Supertonic3Manager
            if let supertonicManager {
                manager = supertonicManager
            } else {
                let created = Supertonic3Manager()
                try await created.initialize()
                supertonicManager = created
                manager = created
            }

            guard let voice = Supertonic3Voice(name: configuration.supertonicVoice.rawValue) else {
                throw SpeechModelError.invalidVoice(configuration.supertonicVoice.rawValue)
            }
            let style = try await Supertonic3ResourceDownloader.loadVoiceStyle(voice)
            let result = try await manager.synthesize(
                text: text,
                language: configuration.language.rawValue,
                style: style
            )
            return try AudioWAV.data(
                from: result.samples,
                sampleRate: Double(Supertonic3Constants.sampleRate),
                normalize: false
            )

        case .kokoroAne:
            let manager: KokoroAneManager
            if let kokoroManager {
                manager = kokoroManager
            } else {
                let created = KokoroAneManager(defaultVoice: KokoroAneConstants.defaultVoice)
                try await created.initialize()
                kokoroManager = created
                manager = created
            }
            let result = try await manager.synthesizeDetailed(text: text)
            return try AudioWAV.data(
                from: result.samples,
                sampleRate: Double(result.sampleRate),
                normalize: false
            )

        case .pocketTTS:
            let manager = try await pocketTtsManager(configuration: configuration)
            let result = try await manager.synthesizeDetailed(
                text: text,
                voice: configuration.pocketVoice.rawValue
            )
            return result.audio

        case .styleTTS2:
            guard let referenceAudioURL = configuration.styleTTS2ReferenceAudioURL else {
                throw SpeechModelError.missingStyleTTS2ReferenceAudio
            }
            let manager = try await styleTTS2ManagerInstance()
            let preparedReferenceAudioURL =
                try prepareStyleTTS2ReferenceAudio(from: referenceAudioURL)
            defer {
                try? FileManager.default.removeItem(at: preparedReferenceAudioURL)
            }
            let samples = try await manager.synthesize(
                text: text,
                referenceAudioURL: preparedReferenceAudioURL
            )
            return try AudioWAV.data(
                from: samples,
                sampleRate: Double(StyleTTS2Constants.sampleRate),
                normalize: false
            )

        case .openRouter:
            return try await OpenRouterSpeechService.synthesize(
                text: text,
                model: configuration.openRouterModel,
                voice: configuration.openRouterVoice,
                apiKey: configuration.openRouterAPIKey,
                apiKeyEnvironmentVariable: configuration.openRouterAPIKeyEnvironmentVariable
            )
        }
    }

    private func pocketTtsManager(
        configuration: SpeechOutputConfiguration
    ) async throws -> PocketTtsManager {
        if let pocketManager {
            return pocketManager
        }

        let created = PocketTtsManager(
            defaultVoice: configuration.pocketVoice.rawValue,
            language: .english,
            precision: .int8,
            placement: .gpu
        )
        try await created.initialize()
        pocketManager = created
        return created
    }

    private func styleTTS2ManagerInstance() async throws -> StyleTTS2Manager {
        if let styleTTS2Manager {
            return styleTTS2Manager
        }

        let created = StyleTTS2Manager()
        try await created.initialize()
        styleTTS2Manager = created
        return created
    }

    private func playPocketStreaming(
        _ text: String,
        manager: PocketTtsManager,
        voice: String,
        generation: Int,
        onProgress: ((Double) -> Void)?
    ) async throws {
        guard generation == requestGeneration else {
            throw CancellationError()
        }

        let stream = try await manager.synthesizeStreaming(
            text: text,
            voice: voice
        )
        try await playPocketFrames(
            stream,
            generation: generation,
            estimatedTotalSamples: PocketStreamingPlaybackProgress.estimatedTotalSamples(
                for: text
            ),
            onProgress: onProgress,
            onFrameScheduled: nil,
            onFramePlayed: nil,
            onSynthesisFinished: nil
        )
    }

    private func playPocketFrames(
        _ stream: AsyncThrowingStream<PocketTtsSynthesizer.AudioFrame, Error>,
        generation: Int,
        estimatedTotalSamples: Int64,
        onProgress: ((Double) -> Void)?,
        onFrameScheduled: (@Sendable (PocketTtsSynthesizer.AudioFrame) -> Void)?,
        onFramePlayed: (@Sendable (PocketTtsSynthesizer.AudioFrame) -> Void)?,
        onSynthesisFinished: (@Sendable () -> Void)?
    ) async throws {
        guard generation == requestGeneration else {
            throw CancellationError()
        }

        let engine = AVAudioEngine()
        let streamingPlayer = AVAudioPlayerNode()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(PocketTtsConstants.audioSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechPlaybackError.couldNotPrepare
        }

        engine.attach(streamingPlayer)
        engine.connect(streamingPlayer, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw SpeechPlaybackError.couldNotStart
        }

        self.streamingEngine = engine
        self.streamingPlayer = streamingPlayer

        let playbackState = PocketStreamingPlaybackState()
        onProgress?(0)

        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      generation == self.requestGeneration else {
                    return
                }

                let snapshot = playbackState.snapshot(
                    estimatedTotalSamples: estimatedTotalSamples
                )
                onProgress?(snapshot.progress)
                if snapshot.isComplete {
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        var playbackStarted = false
        do {
            for try await frame in stream {
                try Task.checkCancellation()
                guard generation == requestGeneration else {
                    throw CancellationError()
                }

                let buffer = try makePocketStreamingPCMBuffer(from: frame.samples)
                let sampleCount = Int64(frame.samples.count)
                playbackState.didSchedule(sampleCount: sampleCount)
                onFrameScheduled?(frame)
                streamingPlayer.scheduleBuffer(
                    buffer,
                    completionCallbackType: .dataPlayedBack
                ) { _ in
                    playbackState.didPlay(sampleCount: sampleCount)
                    onFramePlayed?(frame)
                }

                if !playbackStarted,
                   playbackState.scheduledFrameCount
                    >= Self.pocketStreamingStartupFrameCount {
                    streamingPlayer.play()
                    guard streamingPlayer.isPlaying else {
                        throw SpeechPlaybackError.couldNotStart
                    }
                    playbackStarted = true
                }
            }

            guard playbackState.hasScheduledAudio else {
                throw SpeechPlaybackError.couldNotPrepare
            }

            playbackState.didFinishSynthesis()
            onSynthesisFinished?()
            if !playbackStarted {
                streamingPlayer.play()
                guard streamingPlayer.isPlaying else {
                    throw SpeechPlaybackError.couldNotStart
                }
            }

            await progressTask.value
            try Task.checkCancellation()
            guard generation == requestGeneration else {
                throw CancellationError()
            }
            onProgress?(1)
            finishStreamingPlayback(engine: engine, player: streamingPlayer)
        } catch {
            progressTask.cancel()
            finishStreamingPlayback(engine: engine, player: streamingPlayer)
            throw error
        }
    }

    private func finishStreamingPlayback(
        engine: AVAudioEngine,
        player: AVAudioPlayerNode
    ) {
        guard streamingPlayer === player,
              streamingEngine === engine else { return }

        streamingPlayer = nil
        streamingEngine = nil
        enqueueStreamingTeardown(engine: engine, player: player)
    }

    private func enqueueStreamingTeardown(
        engine: AVAudioEngine?,
        player: AVAudioPlayerNode?
    ) {
        guard engine != nil || player != nil else { return }

        // AVAudioPlayerNode.stop() can wait for AVFoundation's Default-QoS
        // render thread. Keep that synchronous wait off the main actor and at
        // the same QoS as the thread it may need to finish.
        let teardown = StreamingPlaybackTeardown(engine: engine, player: player)
        streamingTeardownQueue.async {
            teardown.run()
        }
    }

    private func play(
        _ data: Data,
        generation: Int,
        onProgress: ((Double) -> Void)?
    ) async throws {
        guard generation == requestGeneration else {
            throw CancellationError()
        }

        let newPlayer = try AVAudioPlayer(data: data)
        guard newPlayer.prepareToPlay() else {
            throw SpeechPlaybackError.couldNotPrepare
        }
        player = newPlayer
        guard newPlayer.play() else {
            player = nil
            throw SpeechPlaybackError.couldNotStart
        }
        onProgress?(0)

        do {
            while newPlayer.isPlaying {
                try Task.checkCancellation()
                guard generation == requestGeneration else {
                    throw CancellationError()
                }
                let fraction = newPlayer.duration > 0
                    ? min(max(newPlayer.currentTime / newPlayer.duration, 0), 1)
                    : 0
                onProgress?(fraction)
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if player === newPlayer {
                newPlayer.stop()
                player = nil
            }
            throw error
        }

        if player === newPlayer {
            onProgress?(1)
            player = nil
        }
    }
}

@MainActor
func makePocketStreamingPCMBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
    guard !samples.isEmpty,
          let format = AVAudioFormat(
              commonFormat: .pcmFormatFloat32,
              sampleRate: Double(PocketTtsConstants.audioSampleRate),
              channels: 1,
              interleaved: false
          ),
          let buffer = AVAudioPCMBuffer(
              pcmFormat: format,
              frameCapacity: AVAudioFrameCount(samples.count)
          ),
          let channelData = buffer.floatChannelData else {
        throw SpeechPlaybackError.couldNotPrepare
    }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
        guard let baseAddress = source.baseAddress else { return }
        channelData[0].update(from: baseAddress, count: samples.count)
    }
    return buffer
}

@MainActor
func decodeSpeechAudioData(_ data: Data) throws -> AVAudioPCMBuffer {
    guard !data.isEmpty else {
        throw SpeechPlaybackError.couldNotPrepare
    }

    let isWAV = data.count >= 4
        && data.prefix(4).elementsEqual("RIFF".utf8)
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(isWAV ? "wav" : "mp3")
    try data.write(to: fileURL, options: .atomic)
    defer {
        try? FileManager.default.removeItem(at: fileURL)
    }

    let audioFile = try AVAudioFile(forReading: fileURL)
    guard audioFile.length > 0,
          audioFile.length <= Int64(UInt32.max),
          let buffer = AVAudioPCMBuffer(
              pcmFormat: audioFile.processingFormat,
              frameCapacity: AVAudioFrameCount(audioFile.length)
          ) else {
        throw SpeechPlaybackError.couldNotPrepare
    }
    try audioFile.read(into: buffer)
    guard buffer.frameLength > 0 else {
        throw SpeechPlaybackError.couldNotPrepare
    }
    return buffer
}

/// FluidAudio 0.15.5's StyleTTS2 reference encoder has a fixed 231-frame mel
/// input. Feed it an exact-length 24 kHz mono WAV so longer user recordings do
/// not fail with a Core ML shape mismatch.
func prepareStyleTTS2ReferenceAudio(from sourceURL: URL) throws -> URL {
    let sourceFile = try AVAudioFile(forReading: sourceURL)
    guard sourceFile.length > 0,
          sourceFile.length <= Int64(UInt32.max),
          let sourceBuffer = AVAudioPCMBuffer(
              pcmFormat: sourceFile.processingFormat,
              frameCapacity: AVAudioFrameCount(sourceFile.length)
          ),
          let targetFormat = AVAudioFormat(
              commonFormat: .pcmFormatFloat32,
              sampleRate: Double(StyleTTS2Constants.sampleRate),
              channels: 1,
              interleaved: false
          ) else {
        throw SpeechPlaybackError.couldNotPrepare
    }
    try sourceFile.read(into: sourceBuffer)
    guard sourceBuffer.frameLength > 0,
          let converter = AVAudioConverter(
              from: sourceBuffer.format,
              to: targetFormat
          ) else {
        throw SpeechPlaybackError.couldNotPrepare
    }

    let sampleRateRatio =
        targetFormat.sampleRate / sourceBuffer.format.sampleRate
    let outputCapacity = AVAudioFrameCount(
        ceil(Double(sourceBuffer.frameLength) * sampleRateRatio) + 32
    )
    guard let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: outputCapacity
    ) else {
        throw SpeechPlaybackError.couldNotPrepare
    }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(
        to: convertedBuffer,
        error: &conversionError
    ) { _, inputStatus in
        if suppliedInput {
            inputStatus.pointee = .endOfStream
            return nil
        }
        suppliedInput = true
        inputStatus.pointee = .haveData
        return sourceBuffer
    }
    guard status != .error,
          conversionError == nil,
          convertedBuffer.frameLength > 0,
          let channelData = convertedBuffer.floatChannelData else {
        throw conversionError ?? SpeechPlaybackError.couldNotPrepare
    }

    let convertedSamples = Array(
        UnsafeBufferPointer(
            start: channelData[0],
            count: Int(convertedBuffer.frameLength)
        )
    )
    let normalizedSamples = normalizedStyleTTS2ReferenceSamples(
        convertedSamples
    )
    let wavData = try AudioWAV.data(
        from: normalizedSamples,
        sampleRate: Double(StyleTTS2Constants.sampleRate),
        normalize: false
    )
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("styletts2-reference-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    try wavData.write(to: outputURL, options: .atomic)
    return outputURL
}

func normalizedStyleTTS2ReferenceSamples(_ samples: [Float]) -> [Float] {
    let requiredMelFrames = 231
    let targetCount =
        (requiredMelFrames - 1) * StyleTTS2Constants.melHopLength
    guard !samples.isEmpty else {
        return [Float](repeating: 0, count: targetCount)
    }

    let peak = samples.reduce(Float.zero) {
        max($0, abs($1))
    }
    let silenceThreshold = max(peak * 0.02, 0.0005)
    let firstSpeech = samples.firstIndex {
        abs($0) >= silenceThreshold
    } ?? samples.startIndex
    let lastSpeech = samples.lastIndex {
        abs($0) >= silenceThreshold
    } ?? samples.index(before: samples.endIndex)
    let margin = StyleTTS2Constants.sampleRate / 10
    let speechStart = max(samples.startIndex, firstSpeech - margin)
    let speechEnd = min(samples.endIndex, lastSpeech + margin + 1)
    let speechSamples = Array(samples[speechStart..<speechEnd])

    if speechSamples.count == targetCount {
        return speechSamples
    }
    if speechSamples.count < targetCount {
        let leadingPadding = (targetCount - speechSamples.count) / 2
        var result = [Float](repeating: 0, count: targetCount)
        result.replaceSubrange(
            leadingPadding..<(leadingPadding + speechSamples.count),
            with: speechSamples
        )
        return result
    }

    var windowEnergy = speechSamples[..<targetCount].reduce(Double.zero) {
        $0 + Double($1 * $1)
    }
    var bestEnergy = windowEnergy
    var bestStart = 0
    for start in 1...(speechSamples.count - targetCount) {
        let leaving = speechSamples[start - 1]
        let entering = speechSamples[start + targetCount - 1]
        windowEnergy += Double(entering * entering - leaving * leaving)
        if windowEnergy > bestEnergy {
            bestEnergy = windowEnergy
            bestStart = start
        }
    }
    return Array(speechSamples[bestStart..<(bestStart + targetCount)])
}

@MainActor
func speechPCMBufferSlices(
    _ source: AVAudioPCMBuffer,
    duration: TimeInterval = 0.08
) throws -> [AVAudioPCMBuffer] {
    let format = source.format
    guard source.frameLength > 0,
          duration > 0,
          format.commonFormat == .pcmFormatFloat32,
          !format.isInterleaved,
          let sourceChannels = source.floatChannelData else {
        throw SpeechPlaybackError.couldNotPrepare
    }

    let framesPerSlice = max(
        1,
        Int((format.sampleRate * duration).rounded())
    )
    let totalFrames = Int(source.frameLength)
    let channelCount = Int(format.channelCount)
    var slices: [AVAudioPCMBuffer] = []
    slices.reserveCapacity(
        Int(ceil(Double(totalFrames) / Double(framesPerSlice)))
    )

    var offset = 0
    while offset < totalFrames {
        let frameCount = min(framesPerSlice, totalFrames - offset)
        guard let slice = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ),
        let destinationChannels = slice.floatChannelData else {
            throw SpeechPlaybackError.couldNotPrepare
        }
        slice.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<channelCount {
            destinationChannels[channel].update(
                from: sourceChannels[channel].advanced(by: offset),
                count: frameCount
            )
        }
        slices.append(slice)
        offset += frameCount
    }
    return slices
}

nonisolated func audioFormatsMatch(
    _ lhs: AVAudioFormat,
    _ rhs: AVAudioFormat
) -> Bool {
    lhs.commonFormat == rhs.commonFormat
        && lhs.sampleRate == rhs.sampleRate
        && lhs.channelCount == rhs.channelCount
        && lhs.isInterleaved == rhs.isInterleaved
}

struct PocketStreamingPlaybackSnapshot: Equatable {
    let progress: Double
    let isComplete: Bool
}

final class PocketStreamingPlaybackState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduledSamples: Int64 = 0
    private var playedSamples: Int64 = 0
    private var scheduledFrames = 0
    private var synthesisFinished = false

    var scheduledFrameCount: Int {
        lock.withLock { scheduledFrames }
    }

    var hasScheduledAudio: Bool {
        lock.withLock { scheduledSamples > 0 }
    }

    func didSchedule(sampleCount: Int64) {
        lock.withLock {
            scheduledSamples += max(sampleCount, 0)
            scheduledFrames += 1
        }
    }

    func didPlay(sampleCount: Int64) {
        lock.withLock {
            playedSamples += max(sampleCount, 0)
        }
    }

    func didFinishSynthesis() {
        lock.withLock {
            synthesisFinished = true
        }
    }

    func snapshot(estimatedTotalSamples: Int64) -> PocketStreamingPlaybackSnapshot {
        lock.withLock {
            let denominator = synthesisFinished
                ? scheduledSamples
                : max(scheduledSamples, estimatedTotalSamples)
            let isComplete = synthesisFinished
                && scheduledSamples > 0
                && playedSamples >= scheduledSamples
            let progress: Double
            if isComplete {
                progress = 1
            } else if denominator > 0 {
                progress = min(max(Double(playedSamples) / Double(denominator), 0), 0.99)
            } else {
                progress = 0
            }
            return PocketStreamingPlaybackSnapshot(
                progress: progress,
                isComplete: isComplete
            )
        }
    }
}

nonisolated enum PocketStreamingPlaybackProgress {
    static func estimatedTotalSamples(for text: String) -> Int64 {
        let words = text.split(whereSeparator: \.isWhitespace)
        let sentencePauses = text.reduce(into: 0) { count, character in
            if ".?!".contains(character) {
                count += 1
            }
        }
        let commaPauses = text.reduce(into: 0) { count, character in
            if ",;:".contains(character) {
                count += 1
            }
        }
        let estimatedSeconds = max(
            0.4,
            Double(words.count) * 0.38
                + Double(sentencePauses) * 0.35
                + Double(commaPauses) * 0.16
        )
        return Int64(estimatedSeconds * Double(PocketTtsConstants.audioSampleRate))
    }
}

nonisolated struct OpenRouterSpeechChunkAccumulator {
    private static let immediateChunkCount = 2
    private static let preferredCharacters = 600
    private static let maximumCharacters = 900

    private var immediateChunksEmitted = 0
    private var pendingText = ""

    mutating func ingest(_ phrase: String) -> [String] {
        let trimmedPhrase = phrase.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedPhrase.isEmpty else { return [] }

        if immediateChunksEmitted < Self.immediateChunkCount {
            immediateChunksEmitted += 1
            return [trimmedPhrase]
        }

        if pendingText.isEmpty {
            pendingText = trimmedPhrase
        } else {
            let candidate = pendingText + " " + trimmedPhrase
            if candidate.count > Self.maximumCharacters {
                let completed = pendingText
                pendingText = trimmedPhrase
                return [completed]
            }
            pendingText = candidate
        }

        guard pendingText.count >= Self.preferredCharacters else {
            return []
        }
        let completed = pendingText
        pendingText = ""
        return [completed]
    }

    mutating func finish() -> [String] {
        guard !pendingText.isEmpty else { return [] }
        let completed = pendingText
        pendingText = ""
        return [completed]
    }
}

nonisolated struct StreamingSpeechPhraseAccumulator {
    private static let minimumFirstPhraseWords = 4
    private static let minimumLaterPhraseWords = 10
    private static let preferredClauseWords = 18
    private static let maximumWords = 42
    private static let abbreviations: Set<String> = [
        "dr.", "e.g.", "etc.", "fig.", "i.e.", "mr.", "mrs.", "ms.", "no.",
        "prof.", "sr.", "st.", "vs.",
    ]

    private var latestSnapshot = ""
    private var committedPrefix = ""
    private var emittedPhraseCount = 0

    mutating func ingest(_ cumulativeText: String) -> [String] {
        guard cumulativeText.hasPrefix(committedPrefix) else {
            // Cumulative model snapshots should be append-only. If a provider
            // briefly emits an older or rewritten snapshot, retain the already
            // spoken prefix and wait for a compatible snapshot instead of
            // repeating or contradicting speech.
            return []
        }

        latestSnapshot = cumulativeText
        return drain(flushRemainder: false)
    }

    mutating func finish() -> [String] {
        drain(flushRemainder: true)
    }

    private mutating func drain(flushRemainder: Bool) -> [String] {
        var phrases: [String] = []

        while latestSnapshot.hasPrefix(committedPrefix) {
            let remainder = String(latestSnapshot.dropFirst(committedPrefix.count))
            let leadingWhitespaceCount = remainder.prefix(while: \.isWhitespace).count
            if leadingWhitespaceCount > 0 {
                committedPrefix = String(
                    latestSnapshot.prefix(committedPrefix.count + leadingWhitespaceCount)
                )
                continue
            }
            guard !remainder.isEmpty else { break }

            let minimumWords = emittedPhraseCount == 0
                ? Self.minimumFirstPhraseWords
                : Self.minimumLaterPhraseWords
            let boundary = Self.safeBoundary(
                in: remainder,
                minimumWords: minimumWords
            )
            if boundary == nil, !flushRemainder {
                break
            }

            let consumedCount = boundary ?? remainder.count
            let phrase = String(remainder.prefix(consumedCount))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            committedPrefix = String(
                latestSnapshot.prefix(committedPrefix.count + consumedCount)
            )
            if !phrase.isEmpty {
                phrases.append(phrase)
                emittedPhraseCount += 1
            }
        }

        return phrases
    }

    private static func safeBoundary(
        in text: String,
        minimumWords: Int
    ) -> Int? {
        var wordCount = 0
        var isInsideWord = false
        var lastClauseBoundary: Int?
        var lastWordBoundary: Int?

        for index in text.indices {
            let character = text[index]
            let nextIndex = text.index(after: index)
            let offsetAfterCharacter = text.distance(
                from: text.startIndex,
                to: nextIndex
            )

            if character.isWhitespace {
                isInsideWord = false
                lastWordBoundary = offsetAfterCharacter
                continue
            }
            if !isInsideWord {
                wordCount += 1
                isInsideWord = true
            }

            if ",;:".contains(character),
               isBoundaryFollowedByWhitespaceOrEnd(nextIndex, in: text) {
                lastClauseBoundary = offsetAfterCharacter
                if wordCount >= preferredClauseWords {
                    return offsetAfterCharacter
                }
            }

            if ".?!".contains(character),
               isBoundaryFollowedByWhitespaceOrEnd(nextIndex, in: text),
               !isFalsePeriodBoundary(at: index, in: text),
               wordCount >= minimumWords {
                return offsetAfterCharacter
            }

            if wordCount >= maximumWords {
                return lastClauseBoundary ?? lastWordBoundary
            }
        }

        return nil
    }

    private static func isBoundaryFollowedByWhitespaceOrEnd(
        _ index: String.Index,
        in text: String
    ) -> Bool {
        index == text.endIndex || text[index].isWhitespace
    }

    private static func isFalsePeriodBoundary(
        at index: String.Index,
        in text: String
    ) -> Bool {
        guard text[index] == "." else { return false }

        let previousIndex = index > text.startIndex
            ? text.index(before: index)
            : nil
        let nextIndex = text.index(after: index)
        if let previousIndex,
           text[previousIndex].isNumber,
           nextIndex < text.endIndex,
           text[nextIndex].isNumber {
            return true
        }

        let prefix = text[...index].lowercased()
        return abbreviations.contains {
            prefix.hasSuffix($0)
        }
    }
}

nonisolated final class StreamingPhrasePlaybackState: @unchecked Sendable {
    private struct Phrase {
        let precedingText: String
        let timeline: SpokenResponsePlaybackTimeline
        let estimatedSamples: Int64
        var scheduledSamples: Int64 = 0
        var playedSamples: Int64 = 0
        var generationFinished = false
        var lastProgress = 0.0
    }

    private let lock = NSLock()
    private var cumulativeText = ""
    private var phrases: [Int: Phrase] = [:]
    private var lastPlaybackText = ""

    func register(_ phrase: String) -> Int {
        lock.withLock {
            let precedingText = cumulativeText
            if !cumulativeText.isEmpty {
                cumulativeText += " "
            }
            cumulativeText += phrase
            let index = phrases.count
            phrases[index] = Phrase(
                precedingText: precedingText,
                timeline: SpokenResponsePlaybackTimeline(text: phrase),
                estimatedSamples: PocketStreamingPlaybackProgress
                    .estimatedTotalSamples(for: phrase)
            )
            return index
        }
    }

    func didSchedule(utteranceIndex: Int, sampleCount: Int64) {
        lock.withLock {
            for earlierIndex in Array(phrases.keys)
                where earlierIndex < utteranceIndex {
                phrases[earlierIndex]?.generationFinished = true
            }
            phrases[utteranceIndex]?.scheduledSamples += sampleCount
        }
    }

    func didFinishGeneration() {
        lock.withLock {
            for index in Array(phrases.keys) {
                phrases[index]?.generationFinished = true
            }
        }
    }

    func didFinishGeneration(utteranceIndex: Int) {
        lock.withLock {
            phrases[utteranceIndex]?.generationFinished = true
        }
    }

    func playbackText(
        utteranceIndex: Int,
        sampleCount: Int64
    ) -> String? {
        lock.withLock {
            guard var phrase = phrases[utteranceIndex] else { return nil }

            phrase.playedSamples += sampleCount
            let denominator = phrase.generationFinished
                ? phrase.scheduledSamples
                : max(phrase.estimatedSamples, phrase.scheduledSamples)
            let measuredProgress = denominator > 0
                ? min(Double(phrase.playedSamples) / Double(denominator), 1)
                : 0
            phrase.lastProgress = max(phrase.lastProgress, measuredProgress)
            phrases[utteranceIndex] = phrase

            let visiblePhrase = phrase.timeline.text(at: phrase.lastProgress)
            let text = [phrase.precedingText, visiblePhrase]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            // A buffer-completion callback for an earlier phrase can land after
            // a later phrase is already audible; its cumulative text is a short
            // prefix. Playback only ever moves forward, so a shorter position is
            // stale, not news — reporting it would drag the reader's highlight
            // (and the page with it) back towards the top of the document.
            guard text.count > lastPlaybackText.count else { return nil }
            lastPlaybackText = text
            return text
        }
    }

    var finalText: String {
        lock.withLock { cumulativeText }
    }
}

nonisolated struct SpokenResponsePlaybackTimeline: Equatable, Sendable {
    private let words: [String]
    private let starts: [Double]
    private let totalWeight: Double

    init(text: String) {
        words = text.split(whereSeparator: \.isWhitespace).map(String.init)

        var runningWeight = 0.0
        var wordStarts: [Double] = []
        wordStarts.reserveCapacity(words.count)
        for word in words {
            wordStarts.append(runningWeight)
            runningWeight += Self.weight(for: word)
        }
        starts = wordStarts
        totalWeight = max(runningWeight, 1)
    }

    func text(at progress: Double) -> String {
        guard !words.isEmpty, progress > 0 else { return "" }
        guard progress < 1 else { return words.joined(separator: " ") }

        let target = min(max(progress, 0), 1) * totalWeight
        let visibleCount = starts.prefix { $0 <= target }.count
        return words.prefix(max(1, visibleCount)).joined(separator: " ")
    }

    private static func weight(for word: String) -> Double {
        let spokenCharacters = word.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }
        var weight = 0.55 + Double(max(spokenCharacters, 1)) * 0.12
        if word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!") {
            weight += 0.8
        } else if word.hasSuffix(";") || word.hasSuffix(":") {
            weight += 0.55
        } else if word.hasSuffix(",") {
            weight += 0.35
        }
        return weight
    }
}

enum SpeechPlaybackError: LocalizedError {
    case couldNotPrepare
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotPrepare:
            return "The synthesized response could not be prepared for playback."
        case .couldNotStart:
            return "The synthesized response could not start playing."
        }
    }
}
