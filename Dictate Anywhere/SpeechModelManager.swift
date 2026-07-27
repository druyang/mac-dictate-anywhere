//
//  SpeechModelManager.swift
//  Dictate Anywhere
//
//  Download, installation, disk-size, and deletion state for FluidAudio TTS models.
//

import Foundation
import FluidAudio

@Observable
@MainActor
final class SpeechModelManager {
    private(set) var installedModels: Set<SpeechSynthesisModel> = []
    private(set) var diskSizes: [SpeechSynthesisModel: Int64] = [:]
    private(set) var activeDownload: SpeechSynthesisModel?
    private(set) var downloadProgress = 0.0
    private(set) var downloadPhase = ""
    private(set) var deletingModel: SpeechSynthesisModel?
    var errorMessage: String?

    func refresh() {
        installedModels = Set(SpeechSynthesisModel.localCases.filter(Self.isDownloaded))
        diskSizes = Dictionary(
            uniqueKeysWithValues: SpeechSynthesisModel.localCases.map {
                ($0, Self.diskUsage(for: $0))
            }
        )
    }

    func isDownloaded(_ model: SpeechSynthesisModel) -> Bool {
        installedModels.contains(model) || Self.isDownloaded(model)
    }

    func diskSize(for model: SpeechSynthesisModel) -> Int64 {
        diskSizes[model] ?? Self.diskUsage(for: model)
    }

    func formattedDiskSize(for model: SpeechSynthesisModel) -> String? {
        let bytes = diskSize(for: model)
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func download(
        _ model: SpeechSynthesisModel,
        supertonicVoice: SupertonicVoiceChoice
    ) async throws {
        guard activeDownload == nil else { return }

        errorMessage = nil
        activeDownload = model
        downloadProgress = 0
        downloadPhase = "Preparing…"
        defer {
            activeDownload = nil
            downloadPhase = ""
            refresh()
        }

        do {
            switch model {
            case .supertonic3:
                try await Supertonic3ResourceDownloader.ensureModels(
                    progressHandler: progressHandler(base: 0, weight: 0.96)
                )
                guard let voice = Supertonic3Voice(name: supertonicVoice.rawValue) else {
                    throw SpeechModelError.invalidVoice(supertonicVoice.rawValue)
                }
                _ = try await Supertonic3ResourceDownloader.downloadVoiceStyle(
                    voice,
                    progressHandler: progressHandler(base: 0.96, weight: 0.04)
                )

            case .kokoroAne:
                try await KokoroAneResourceDownloader.ensureModels(
                    variant: .english,
                    progressHandler: progressHandler(base: 0, weight: 0.88)
                )
                try await KokoroAneResourceDownloader.ensureG2PAssets(
                    progressHandler: progressHandler(base: 0.88, weight: 0.12)
                )
                _ = await KokoroAneResourceDownloader.ensureEnglishLexicon()

            case .pocketTTS:
                _ = try await PocketTtsResourceDownloader.ensureModels(
                    language: .english,
                    precision: .int8,
                    placement: .gpu,
                    progressHandler: progressHandler(base: 0, weight: 1)
                )

            case .openRouter:
                throw SpeechModelError.cloudModelDoesNotDownload
            }
            downloadProgress = 1
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func delete(_ model: SpeechSynthesisModel) throws {
        guard activeDownload == nil else {
            throw SpeechModelError.downloadInProgress
        }

        errorMessage = nil
        deletingModel = model
        defer {
            deletingModel = nil
            refresh()
        }

        do {
            for url in Self.deletableURLs(for: model) where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    nonisolated static func isDownloaded(_ model: SpeechSynthesisModel) -> Bool {
        guard model.isLocal else { return false }
        return requiredURLs(for: model).allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func progressHandler(
        base: Double,
        weight: Double
    ) -> DownloadUtils.ProgressHandler {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                downloadProgress = min(1, base + progress.fractionCompleted * weight)
                switch progress.phase {
                case .listing:
                    downloadPhase = "Checking files…"
                case .downloading(let completed, let total):
                    downloadPhase = total > 0
                        ? "Downloading file \(min(completed + 1, total)) of \(total)…"
                        : "Downloading…"
                case .compiling(let modelName):
                    downloadPhase = modelName.isEmpty
                        ? "Preparing Core ML models…"
                        : "Preparing \(modelName)…"
                }
            }
        }
    }

    private nonisolated static var modelsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("fluidaudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private nonisolated static func requiredURLs(
        for model: SpeechSynthesisModel
    ) -> [URL] {
        switch model {
        case .supertonic3:
            let root = modelsRoot.appendingPathComponent(Repo.supertonic3.folderName)
            return ModelNames.Supertonic3.requiredFiles.map {
                root.appendingPathComponent($0)
            }

        case .kokoroAne:
            let modelRoot = modelsRoot.appendingPathComponent(Repo.kokoroAne.folderName)
            let g2pRoot = modelsRoot.appendingPathComponent(Repo.kokoro.folderName)
            return ModelNames.KokoroAne.requiredModels.map {
                modelRoot.appendingPathComponent($0)
            } + ModelNames.G2P.requiredModels.map {
                g2pRoot.appendingPathComponent($0)
            }

        case .pocketTTS:
            let root = modelsRoot
                .appendingPathComponent(Repo.pocketTts.folderName)
                .appendingPathComponent(PocketTtsLanguage.english.repoSubdirectory)
            return ModelNames.PocketTTS.requiredModels(
                precision: .int8,
                placement: .gpu
            ).map {
                root.appendingPathComponent($0)
            }

        case .openRouter:
            return []
        }
    }

    private nonisolated static func storageURLs(
        for model: SpeechSynthesisModel
    ) -> [URL] {
        switch model {
        case .supertonic3:
            return [modelsRoot.appendingPathComponent(Repo.supertonic3.folderName)]
        case .kokoroAne:
            return [
                modelsRoot.appendingPathComponent(Repo.kokoroAne.folderName),
                modelsRoot.appendingPathComponent(Repo.kokoro.folderName),
            ]
        case .pocketTTS:
            return [
                modelsRoot
                    .appendingPathComponent(Repo.pocketTts.folderName)
                    .appendingPathComponent(PocketTtsLanguage.english.repoSubdirectory)
            ]
        case .openRouter:
            return []
        }
    }

    private nonisolated static func deletableURLs(
        for model: SpeechSynthesisModel
    ) -> [URL] {
        guard model == .kokoroAne else { return storageURLs(for: model) }

        var urls = [modelsRoot.appendingPathComponent(Repo.kokoroAne.folderName)]
        let styleTTSRoot = modelsRoot.appendingPathComponent(Repo.styletts2.folderName)
        if !FileManager.default.fileExists(atPath: styleTTSRoot.path) {
            urls.append(modelsRoot.appendingPathComponent(Repo.kokoro.folderName))
        }
        return urls
    }

    private nonisolated static func diskUsage(
        for model: SpeechSynthesisModel
    ) -> Int64 {
        storageURLs(for: model).reduce(0) { $0 + diskUsage(at: $1) }
    }

    private nonisolated static func diskUsage(at root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

enum SpeechModelError: LocalizedError {
    case downloadInProgress
    case cloudModelDoesNotDownload
    case invalidVoice(String)
    case modelNotDownloaded(SpeechSynthesisModel)

    var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            return "Wait for the current speech-model download to finish."
        case .cloudModelDoesNotDownload:
            return "OpenRouter speech models run in the cloud and do not need to be downloaded."
        case .invalidVoice(let voice):
            return "The selected voice \(voice) is not available."
        case .modelNotDownloaded(let model):
            return "Download \(model.displayName) in Speech Model settings before using it."
        }
    }
}
