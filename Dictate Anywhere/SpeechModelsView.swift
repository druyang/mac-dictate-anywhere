//
//  SpeechModelsView.swift
//  Dictate Anywhere
//
//  Select and preview local FluidAudio or OpenRouter cloud TTS models.
//

import SwiftUI

struct SpeechModelsView: View {
    @Environment(AppState.self) private var appState

    @State private var pendingDeletion: SpeechSynthesisModel?
    @State private var isPreviewing = false
    @State private var openRouterModels: [OpenRouterSpeechService.Model] = []
    @State private var openRouterStatusMessage: String?
    @State private var openRouterSearch = ""
    @State private var isRefreshingOpenRouter = false

    var body: some View {
        @Bindable var settings = appState.settings
        let manager = appState.speechModelManager
        let selectedModel = settings.speechSynthesisModel
        let speechConfiguration = SpeechOutputConfiguration(settings: settings)

        DSPage {
            DSSectionHeader(
                title: "Speech Model",
                subtitle: "Choose a local FluidAudio voice or an OpenRouter cloud speech model."
            )

            DSSection(overline: "Active Voice") {
                DSDetailRow(
                    label: "Model",
                    caption: selectedModel.detail
                ) {
                    DSDropdown(
                        selection: $settings.speechSynthesisModel,
                        options: SpeechSynthesisModel.allCases,
                        title: \.displayName,
                        isEnabled: appState.status == .idle && manager.activeDownload == nil
                    )
                }
                DSDivider()
                voiceConfiguration(settings: settings, model: selectedModel)
                DSDivider()
                DSInfoRow(label: "Preview") {
                    Button(isPreviewing ? "Speaking…" : "Play Voice Sample") {
                        isPreviewing = true
                        Task {
                            await appState.previewSpeechOutput()
                            isPreviewing = false
                        }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(
                        isPreviewing
                            || appState.status != .idle
                            || !speechConfiguration.isReady
                    )
                }
            }

            DSSection(overline: "FluidAudio Models") {
                ForEach(Array(SpeechSynthesisModel.localCases.enumerated()), id: \.element) { index, model in
                    if index > 0 {
                        DSDivider()
                    }
                    modelRow(model, manager: manager, selectedModel: selectedModel)
                }
            }

            openRouterConfiguration(settings: settings)

            if let error = manager.errorMessage {
                DSPanel(text: error, tone: .danger)
            }

            DSPanel(
                text: "OpenRouter uses the same Keychain-backed API key everywhere in Dictate Anywhere. Changing it here also changes it for Voice Assistant and Transcript Cleanup.",
                tone: .info
            )
        }
        .task {
            manager.refresh()
            await refreshOpenRouterModels()
        }
        .alert(
            "Delete \(pendingDeletion?.displayName ?? "Speech Model")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let model = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    await appState.deleteSpeechModel(model)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            let model = pendingDeletion ?? selectedModel
            Text(
                "This removes \(manager.formattedDiskSize(for: model) ?? model.sizeSummary) of local model files. You can download them again later."
            )
        }
    }

    @ViewBuilder
    private func voiceConfiguration(
        settings: Settings,
        model: SpeechSynthesisModel
    ) -> some View {
        switch model {
        case .supertonic3:
            DSInfoRow(label: "Voice") {
                DSDropdown(
                    selection: Binding(
                        get: { settings.supertonicVoice },
                        set: { settings.supertonicVoice = $0 }
                    ),
                    options: SupertonicVoiceChoice.allCases,
                    title: \.displayName,
                    isEnabled: appState.status == .idle
                )
            }
            DSDivider()
            DSInfoRow(label: "Language") {
                DSDropdown(
                    selection: Binding(
                        get: { settings.speechOutputLanguage },
                        set: { settings.speechOutputLanguage = $0 }
                    ),
                    options: SpeechOutputLanguage.allCases,
                    title: \.displayName,
                    isEnabled: appState.status == .idle
                )
            }

        case .kokoroAne:
            DSInfoRow(label: "Voice", value: "Heart")
            DSDivider()
            DSInfoRow(label: "Language", value: "English")

        case .pocketTTS:
            DSInfoRow(label: "Voice") {
                DSDropdown(
                    selection: Binding(
                        get: { settings.pocketVoice },
                        set: { settings.pocketVoice = $0 }
                    ),
                    options: PocketVoiceChoice.allCases,
                    title: \.displayName,
                    isEnabled: appState.status == .idle
                )
            }
            DSDivider()
            DSInfoRow(label: "Language", value: "English")

        case .openRouter:
            DSInfoRow(
                label: "Model",
                value: settings.openRouterSpeechModel.isEmpty
                    ? "Choose below"
                    : settings.openRouterSpeechModel
            )
            DSDivider()
            DSInfoRow(
                label: "Voice",
                value: settings.openRouterSpeechVoice.isEmpty
                    ? "Choose below"
                    : settings.openRouterSpeechVoice
            )
        }
    }

    private func openRouterConfiguration(settings: Settings) -> some View {
        DSSection(overline: "OpenRouter Cloud Speech") {
            fieldRow(label: "Shared API Key") {
                DSTextField(
                    placeholder: "Paste OpenRouter API key",
                    text: Binding(
                        get: { settings.openRouterAPIKey },
                        set: { settings.openRouterAPIKey = $0 }
                    ),
                    isSecure: true
                )
            }
            DSDivider()
            fieldRow(label: "Environment Variable") {
                DSTextField(
                    placeholder: OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable,
                    text: Binding(
                        get: { settings.openRouterAPIKeyEnvironmentVariable },
                        set: { settings.openRouterAPIKeyEnvironmentVariable = $0 }
                    )
                )
            }
            DSDivider()
            fieldRow(label: "Speech Model") {
                DSTextField(
                    placeholder: "qwen/qwen-audio-3.0-tts-flash",
                    text: Binding(
                        get: { settings.openRouterSpeechModel },
                        set: { settings.openRouterSpeechModel = $0 }
                    )
                )
            }
            DSDivider()
            fieldRow(label: "Voice") {
                openRouterVoiceControl(settings: settings)
            }
            DSDivider()
            HStack(spacing: 12) {
                if isRefreshingOpenRouter {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(openRouterStatusMessage ?? openRouterStatus(settings: settings))
                    .font(DS.Fonts.ui(12.5))
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer(minLength: 12)
                Button(isRefreshingOpenRouter ? "Refreshing…" : "Refresh Models") {
                    Task {
                        await refreshOpenRouterModels()
                    }
                }
                .buttonStyle(.dsSecondary)
                .disabled(isRefreshingOpenRouter)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, DS.Spacing.rowHorizontal)

            if !openRouterModels.isEmpty {
                DSDivider()
                VStack(alignment: .leading, spacing: 10) {
                    DSSearchField(
                        placeholder: "Filter \(openRouterModels.count) speech models…",
                        text: $openRouterSearch
                    )
                    let models = matchingOpenRouterModels()
                    if models.isEmpty {
                        Text("No OpenRouter speech models match this search.")
                            .font(DS.Fonts.ui(12.5))
                            .foregroundStyle(DS.Colors.textSecondary)
                    } else {
                        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                            if index > 0 {
                                DSDivider()
                            }
                            openRouterModelRow(model, settings: settings)
                        }
                    }
                }
                .padding(DS.Spacing.rowHorizontal)
            }
        }
    }

    @ViewBuilder
    private func openRouterVoiceControl(settings: Settings) -> some View {
        if let model = OpenRouterSpeechService.matchingModel(
            for: settings.openRouterSpeechModel,
            in: openRouterModels
        ), !model.supportedVoices.isEmpty {
            DSDropdown(
                selection: Binding(
                    get: { settings.openRouterSpeechVoice },
                    set: { settings.openRouterSpeechVoice = $0 }
                ),
                options: [""] + model.supportedVoices,
                title: { $0.isEmpty ? "Choose a voice" : $0 },
                isEnabled: appState.status == .idle
            )
        } else {
            DSTextField(
                placeholder: "Voice ID",
                text: Binding(
                    get: { settings.openRouterSpeechVoice },
                    set: { settings.openRouterSpeechVoice = $0 }
                )
            )
        }
    }

    private func openRouterModelRow(
        _ model: OpenRouterSpeechService.Model,
        settings: Settings
    ) -> some View {
        let isSelected = settings.openRouterSpeechModel.caseInsensitiveCompare(model.id) == .orderedSame

        return Button {
            settings.speechSynthesisModel = .openRouter
            settings.openRouterSpeechModel = model.id
            if let firstVoice = model.supportedVoices.first,
               !model.supportedVoices.contains(settings.openRouterSpeechVoice) {
                settings.openRouterSpeechVoice = firstVoice
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.displayName)
                        .font(DS.Fonts.ui(13.5, .semibold))
                        .foregroundStyle(DS.Colors.ink)
                    Text(model.id)
                        .font(DS.Fonts.ui(11.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                    HStack(spacing: 6) {
                        if let price = model.priceSummary {
                            DSChip(text: price)
                        }
                        if !model.supportedVoices.isEmpty {
                            DSChip(
                                text: "\(model.supportedVoices.count) voice\(model.supportedVoices.count == 1 ? "" : "s")"
                            )
                        }
                    }
                }
                Spacer(minLength: 12)
                DSChip(text: isSelected ? "Selected" : "Select", isSelected: isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fieldRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        DSInfoRow(label: label) {
            content()
                .frame(width: 360)
        }
    }

    private func matchingOpenRouterModels() -> [OpenRouterSpeechService.Model] {
        let query = openRouterSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return openRouterModels }
        return openRouterModels.filter {
            $0.id.lowercased().contains(query)
                || $0.displayName.lowercased().contains(query)
                || $0.description.lowercased().contains(query)
        }
    }

    private func openRouterStatus(settings: Settings) -> String {
        let keyStatus = OpenRouterPostProcessingService.apiKeyStatus(
            apiKey: settings.openRouterAPIKey,
            apiKeyEnvironmentVariable: settings.openRouterAPIKeyEnvironmentVariable
        )
        guard keyStatus.isConfigured else {
            return "Add the shared OpenRouter API key to preview or use cloud speech."
        }
        guard !settings.openRouterSpeechModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Choose a speech model from the catalog."
        }
        guard !settings.openRouterSpeechVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Choose or enter a voice for the selected model."
        }
        return "\(settings.openRouterSpeechModel) is ready to preview."
    }

    @MainActor
    private func refreshOpenRouterModels() async {
        guard !isRefreshingOpenRouter else { return }
        isRefreshingOpenRouter = true
        defer { isRefreshingOpenRouter = false }

        do {
            openRouterModels = try await OpenRouterSpeechService.fetchModels()
            openRouterStatusMessage = nil

            let settings = appState.settings
            if let selected = OpenRouterSpeechService.matchingModel(
                for: settings.openRouterSpeechModel,
                in: openRouterModels
            ), let firstVoice = selected.supportedVoices.first,
               !selected.supportedVoices.contains(settings.openRouterSpeechVoice) {
                settings.openRouterSpeechVoice = firstVoice
            }
        } catch {
            openRouterModels = []
            openRouterStatusMessage = error.localizedDescription
        }
    }

    private func modelRow(
        _ model: SpeechSynthesisModel,
        manager: SpeechModelManager,
        selectedModel: SpeechSynthesisModel
    ) -> some View {
        let isInstalled = manager.isDownloaded(model)
        let isDownloading = manager.activeDownload == model
        let diskSize = manager.formattedDiskSize(for: model)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(model.displayName)
                            .font(DS.Fonts.ui(14, .semibold))
                            .foregroundStyle(DS.Colors.ink)
                        if model == selectedModel {
                            DSChip(text: "Selected")
                        }
                    }
                    Text(model.detail)
                        .font(DS.Fonts.ui(12.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if isInstalled {
                    DSStatusPill(text: "Ready")
                } else if isDownloading {
                    DSStatusPill(text: "Downloading", tone: .info)
                } else {
                    DSStatusPill(text: "Not downloaded", tone: .neutral)
                }
            }

            HStack(spacing: 8) {
                DSChip(text: model.languageSummary)
                DSChip(text: model.sampleRateSummary)
                DSChip(text: model.licenseSummary)
                DSChip(text: diskSize.map { "\($0) on disk" } ?? "\(model.sizeSummary) download")
                Spacer(minLength: 8)

                if isInstalled {
                    Button("Delete…") {
                        pendingDeletion = model
                    }
                    .buttonStyle(.dsDestructive)
                    .disabled(
                        appState.status != .idle
                            || manager.activeDownload != nil
                            || manager.deletingModel != nil
                    )
                } else if !isDownloading {
                    Button("Download") {
                        Task {
                            await appState.downloadSpeechModel(model)
                        }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(
                        appState.status != .idle
                            || manager.activeDownload != nil
                            || manager.deletingModel != nil
                    )
                }
            }

            if isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: manager.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(DS.Colors.accent)
                    HStack {
                        Text(manager.downloadPhase)
                        Spacer()
                        Text("\(Int(manager.downloadProgress * 100))%")
                    }
                    .font(DS.Fonts.ui(11.5))
                    .foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }
}
