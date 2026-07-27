//
//  SpeechOutputService.swift
//  Dictate Anywhere
//
//  Local FluidAudio and OpenRouter cloud text-to-speech playback.
//

import AVFoundation
import Foundation
import FluidAudio

struct SpeechOutputConfiguration: Sendable {
    let model: SpeechSynthesisModel
    let supertonicVoice: SupertonicVoiceChoice
    let pocketVoice: PocketVoiceChoice
    let language: SpeechOutputLanguage
    let openRouterModel: String
    let openRouterVoice: String
    let openRouterAPIKey: String
    let openRouterAPIKeyEnvironmentVariable: String

    init(settings: Settings) {
        model = settings.speechSynthesisModel
        supertonicVoice = settings.supertonicVoice
        pocketVoice = settings.pocketVoice
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
        case .supertonic3, .kokoroAne, .pocketTTS:
            return SpeechModelManager.isDownloaded(model)
        }
    }
}

@MainActor
final class SpeechOutputService {
    private static let pocketStreamingStartupFrameCount = 4

    private var supertonicManager: Supertonic3Manager?
    private var kokoroManager: KokoroAneManager?
    private var pocketManager: PocketTtsManager?
    private var player: AVAudioPlayer?
    private var streamingEngine: AVAudioEngine?
    private var streamingPlayer: AVAudioPlayerNode?
    private var requestGeneration = 0

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

    func stop() {
        requestGeneration += 1
        stopPlayer()
    }

    private func stopPlayer() {
        player?.stop()
        player = nil
        streamingPlayer?.stop()
        streamingEngine?.stop()
        streamingEngine?.reset()
        streamingPlayer = nil
        streamingEngine = nil
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
        case .openRouter:
            break
        }
    }

    private func synthesize(
        _ text: String,
        configuration: SpeechOutputConfiguration
    ) async throws -> Data {
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
        let estimatedTotalSamples = PocketStreamingPlaybackProgress.estimatedTotalSamples(
            for: text
        )
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
                streamingPlayer.scheduleBuffer(
                    buffer,
                    completionCallbackType: .dataPlayedBack
                ) { _ in
                    playbackState.didPlay(sampleCount: sampleCount)
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
        player.stop()
        engine.stop()
        engine.reset()
        if streamingPlayer === player {
            streamingPlayer = nil
        }
        if streamingEngine === engine {
            streamingEngine = nil
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

enum PocketStreamingPlaybackProgress {
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

struct SpokenResponsePlaybackTimeline: Equatable {
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
