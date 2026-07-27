//
//  VoiceAssistantView.swift
//  Dictate Anywhere
//
//  Configuration and smoke-test surface for push-to-talk voice responses.
//

import AppKit
import FoundationModels
import SwiftUI

struct VoiceAssistantView: View {
    @Environment(AppState.self) private var appState

    @State private var ollamaAvailability: OllamaPostProcessingService.Availability?
    @State private var ollamaStatusMessage: String?
    @State private var openRouterAvailability: OpenRouterPostProcessingService.Availability?
    @State private var openRouterStatusMessage: String?
    @State private var openRouterSearch = ""
    @State private var isRefreshing = false

    var body: some View {
        @Bindable var settings = appState.settings
        let codexAvailability = CodexToolService.availability(
            workspacePath: settings.codexWorkspacePath
        )

        DSPage {
            DSSectionHeader(
                title: "Voice Assistant",
                subtitle: "Ask a question with a shortcut and hear the selected model answer."
            )

            DSSection(overline: "Assistant Brain") {
                DSDetailRow(
                    label: "Response provider",
                    caption: "This is independent from Transcript Cleanup. Ask shortcuts use this provider."
                ) {
                    DSDropdown(
                        selection: $settings.agentBrainProvider,
                        options: AgentBrainProvider.allCases,
                        title: \.displayName
                    )
                }
            }

            providerConfiguration(settings: settings)

            DSSection(overline: "System Prompt") {
                SettingsMultilineTextArea(
                    text: $settings.agentSystemPrompt,
                    placeholder: "Describe how the Voice Assistant should respond.",
                    minHeight: 120
                )
                .labelsHidden()
                .padding(DS.Spacing.rowHorizontal)
                DSDivider()
                HStack(spacing: 16) {
                    Text("Used by every assistant provider, including read-only Codex requests.")
                        .font(DS.Fonts.ui(12.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer(minLength: 16)
                    Button("Reset to Default") {
                        settings.agentSystemPrompt = VoiceAgentInstructions.system
                    }
                    .buttonStyle(.dsSecondary)
                    .disabled(settings.agentSystemPrompt == VoiceAgentInstructions.system)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, DS.Spacing.rowHorizontal)
            }

            codexConfiguration(
                settings: settings,
                availability: codexAvailability
            )

            DSPanel(
                text: "In Shortcuts, set a shortcut's action to Ask. Project, repository, file, and git questions automatically use read-only Codex. General questions use the selected assistant brain; OpenRouter can optionally access the web.",
                tone: .neutral,
                icon: "waveform.and.mic"
            )
        }
        .task {
            appState.speechModelManager.refresh()
        }
        .task(id: settings.agentBrainProvider) {
            await refreshSelectedProvider(settings: settings)
        }
    }

    @ViewBuilder
    private func providerConfiguration(settings: Settings) -> some View {
        switch settings.agentBrainProvider {
        case .appleIntelligence:
            appleIntelligenceConfiguration
        case .ollama:
            ollamaConfiguration(settings: settings)
        case .openRouter:
            openRouterConfiguration(settings: settings)
        }
    }

    @ViewBuilder
    private var appleIntelligenceConfiguration: some View {
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                DSPanel(
                    text: "Apple Intelligence is ready. Questions and responses stay on this Mac.",
                    tone: .success
                )
            case .unavailable(.deviceNotEligible):
                DSPanel(
                    text: "This Mac is not eligible for Apple Intelligence. Choose Ollama or OpenRouter.",
                    tone: .danger
                )
            case .unavailable(.appleIntelligenceNotEnabled):
                DSPanel(
                    text: "Enable Apple Intelligence in System Settings, or choose another provider.",
                    tone: .warning
                )
            case .unavailable(.modelNotReady):
                DSPanel(
                    text: "Apple Intelligence is still preparing its on-device model.",
                    tone: .info,
                    icon: "clock"
                )
            @unknown default:
                DSPanel(
                    text: "Apple Intelligence is currently unavailable.",
                    tone: .warning
                )
            }
        } else {
            DSPanel(
                text: "Apple Intelligence responses require macOS 26 or later.",
                tone: .warning
            )
        }
    }

    private func ollamaConfiguration(settings: Settings) -> some View {
        DSSection(overline: "Ollama") {
            fieldRow(label: "Server URL") {
                DSTextField(
                    placeholder: OllamaPostProcessingService.defaultBaseURL,
                    text: Binding(
                        get: { settings.ollamaBaseURL },
                        set: { settings.ollamaBaseURL = $0 }
                    )
                )
            }
            DSDivider()
            fieldRow(label: "Model") {
                DSTextField(
                    placeholder: "gemma4:e4b",
                    text: Binding(
                        get: { settings.ollamaModel },
                        set: { settings.ollamaModel = $0 }
                    )
                )
            }
            DSDivider()
            providerStatusRow(
                message: ollamaStatusMessage ?? ollamaStatus(settings: settings),
                refresh: { await refreshOllama(settings: settings) }
            )

            if let models = ollamaAvailability?.installedModels, !models.isEmpty {
                DSDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Installed Models")
                        .font(DS.Fonts.ui(12, .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                    FlowLayout(spacing: 6) {
                        ForEach(models, id: \.self) { model in
                            Button {
                                settings.ollamaModel = model
                            } label: {
                                DSChip(text: model, isSelected: settings.ollamaModel == model)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(DS.Spacing.rowHorizontal)
            }
        }
    }

    private func openRouterConfiguration(settings: Settings) -> some View {
        DSSection(overline: "OpenRouter") {
            fieldRow(label: "API Key") {
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
            fieldRow(label: "Selected Model") {
                DSTextField(
                    placeholder: "openai/gpt-5-mini",
                    text: Binding(
                        get: { settings.openRouterModel },
                        set: { settings.openRouterModel = $0 }
                    )
                )
            }
            DSDivider()
            DSStackedRow(
                label: "Web access",
                caption: "Let the model search the web when it needs current information. Search requests may incur additional OpenRouter charges.",
                isOn: Binding(
                    get: { settings.agentOpenRouterWebSearchEnabled },
                    set: { settings.agentOpenRouterWebSearchEnabled = $0 }
                )
            )
            DSDivider()
            providerStatusRow(
                message: openRouterStatusMessage ?? openRouterStatus(settings: settings),
                refresh: { await refreshOpenRouter(settings: settings) }
            )

            if let availability = openRouterAvailability {
                DSDivider()
                VStack(alignment: .leading, spacing: 10) {
                    DSSearchField(placeholder: "Filter \(availability.models.count) models…", text: $openRouterSearch)
                    let models = matchingOpenRouterModels(availability)
                    if models.isEmpty {
                        Text("No models match this search.")
                            .font(DS.Fonts.ui(12.5))
                            .foregroundStyle(DS.Colors.textSecondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(models, id: \.id) { model in
                                Button {
                                    settings.openRouterModel = model.id
                                } label: {
                                    DSChip(
                                        text: model.id,
                                        isSelected: settings.openRouterModel.caseInsensitiveCompare(model.id) == .orderedSame
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(DS.Spacing.rowHorizontal)
            }
        }
    }

    private func codexConfiguration(
        settings: Settings,
        availability: CodexToolService.Availability
    ) -> some View {
        DSSection(overline: "Codex Tool") {
            DSStackedRow(
                label: "Allow read-only Codex requests",
                caption: "Project-aware requests are routed automatically; saying Codex explicitly also works. Commands cannot write files, use the web, or leave the selected project.",
                isOn: Binding(
                    get: { settings.codexToolEnabled },
                    set: { settings.codexToolEnabled = $0 }
                )
            )
            .disabled(!availability.isReady)

            DSDivider()

            DSDetailRow(
                label: "Project folder",
                caption: codexWorkspaceCaption(availability)
            ) {
                Button(settings.codexWorkspacePath.isEmpty ? "Choose Project" : "Change Project") {
                    chooseCodexWorkspace(settings: settings)
                }
                .buttonStyle(.dsSecondary)
            }

            DSDivider()

            DSInfoRow(
                label: "Codex CLI",
                value: availability.executablePath == nil
                    ? "Not found"
                    : "Installed"
            )

            if !availability.isInstalled {
                DSDivider()
                DSPanel(
                    text: "Install and sign in to Codex CLI, or set DICTATE_ANYWHERE_CODEX_PATH to its executable.",
                    tone: .warning
                )
            } else if let workspaceError = availability.workspaceError,
                      !settings.codexWorkspacePath.isEmpty {
                DSDivider()
                DSPanel(text: workspaceError, tone: .danger)
            }

            DSDivider()

            Text("Try: “Ask Codex what this project does.” Codex runs ephemerally with no file writes, command network access, connectors, web search, hooks, memories, or subagents.")
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 14)
                .padding(.horizontal, DS.Spacing.rowHorizontal)
        }
    }

    private func codexWorkspaceCaption(
        _ availability: CodexToolService.Availability
    ) -> String {
        if availability.workspacePath.isEmpty {
            return "Choose one Git project. Codex will not be able to read outside it."
        }
        if let workspaceError = availability.workspaceError {
            return workspaceError
        }
        return availability.workspacePath
    }

    private func chooseCodexWorkspace(settings: Settings) {
        let panel = NSOpenPanel()
        panel.title = "Choose a project for read-only Codex access"
        panel.prompt = "Choose Project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let selectedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        settings.codexWorkspacePath = selectedPath
        settings.codexToolEnabled = CodexToolService.workspaceValidationError(selectedPath) == nil
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

    private func providerStatusRow(
        message: String,
        refresh: @escaping @MainActor () async -> Void
    ) -> some View {
        HStack(spacing: 12) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Text(message)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer(minLength: 12)
            Button(isRefreshing ? "Checking…" : "Refresh Models") {
                Task { await refresh() }
            }
            .buttonStyle(.dsSecondary)
            .disabled(isRefreshing)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    private func ollamaStatus(settings: Settings) -> String {
        guard let availability = ollamaAvailability else {
            return "Refresh to connect and select an installed model."
        }
        if availability.installedModels.isEmpty {
            return "Connected, but no models are installed."
        }
        if availability.selectedModelIsInstalled {
            return "\(availability.resolvedSelectedModel ?? availability.selectedModel) is ready."
        }
        return "Connected. Select an installed model below."
    }

    private func openRouterStatus(settings: Settings) -> String {
        let keyStatus = OpenRouterPostProcessingService.apiKeyStatus(
            apiKey: settings.openRouterAPIKey,
            apiKeyEnvironmentVariable: settings.openRouterAPIKeyEnvironmentVariable
        )
        guard keyStatus.isConfigured else {
            return "Add an API key, then refresh the model catalog."
        }
        guard let availability = openRouterAvailability else {
            return "Refresh to load the OpenRouter model catalog."
        }
        if let model = OpenRouterPostProcessingService.matchingAvailableModel(
            for: settings.openRouterModel,
            in: availability
        ) {
            return "\(model.id) is ready."
        }
        return "Choose a model below or enter a model ID."
    }

    private func matchingOpenRouterModels(
        _ availability: OpenRouterPostProcessingService.Availability
    ) -> [OpenRouterPostProcessingService.Model] {
        let query = openRouterSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = query.isEmpty
            ? availability.models
            : availability.models.filter { $0.id.lowercased().contains(query) }
        return Array(matches.prefix(24))
    }

    private func refreshSelectedProvider(settings: Settings) async {
        switch settings.agentBrainProvider {
        case .appleIntelligence:
            return
        case .ollama:
            await refreshOllama(settings: settings)
        case .openRouter:
            await refreshOpenRouter(settings: settings)
        }
    }

    private func refreshOllama(settings: Settings) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            ollamaAvailability = try await OllamaPostProcessingService.availability(
                baseURL: settings.ollamaBaseURL,
                selectedModel: settings.ollamaModel
            )
            ollamaStatusMessage = nil
        } catch {
            ollamaAvailability = nil
            ollamaStatusMessage = error.localizedDescription
        }
    }

    private func refreshOpenRouter(settings: Settings) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            openRouterAvailability = try await OpenRouterPostProcessingService.availability(
                apiKey: settings.openRouterAPIKey,
                apiKeyEnvironmentVariable: settings.openRouterAPIKeyEnvironmentVariable
            )
            openRouterStatusMessage = nil
        } catch {
            openRouterAvailability = nil
            openRouterStatusMessage = error.localizedDescription
        }
    }
}
