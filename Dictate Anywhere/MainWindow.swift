//
//  MainWindow.swift
//  Dictate Anywhere
//
//  Root layout: custom design-system sidebar + detail page.
//

import SwiftUI

enum SpeechReadinessWarning {
    static func message(
        for model: SpeechSynthesisModel,
        isReady: Bool,
        isModelDownloaded: Bool? = nil
    ) -> String? {
        guard !isReady else { return nil }

        if model == .styleTTS2, isModelDownloaded == true {
            return "StyleTTS2 needs a reference recording. Choose one on the Speech Model page."
        }

        if model.isLocal {
            return "\(model.displayName) isn’t downloaded. Download it before speech playback can begin."
        }

        return "OpenRouter speech isn’t ready. Add the shared API key, then choose a speech model and voice."
    }
}

enum SidebarPage: String, CaseIterable, Identifiable {
    case models
    case speechOutput
    case readAloud
    case settings
    case shortcuts
    case voiceAssistant
    case conversationMemory
    case textOverlay
    case aiPostProcessing
    case history
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "Dictation Model"
        case .speechOutput: return "Speech Model"
        case .readAloud: return "Read Aloud"
        case .settings: return "General"
        case .shortcuts: return "Shortcuts"
        case .voiceAssistant: return "Voice Assistant"
        case .conversationMemory: return "Conversation Memory"
        case .textOverlay: return "Text & Overlay"
        case .aiPostProcessing: return "Transcript Cleanup"
        case .history: return "Dictation History"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .models: return "cpu"
        case .speechOutput: return "speaker.wave.3"
        case .readAloud: return "doc.text"
        case .settings: return "slider.horizontal.3"
        case .shortcuts: return "command"
        case .voiceAssistant: return "waveform.and.mic"
        case .conversationMemory: return "bubble.left.and.bubble.right"
        case .textOverlay: return "textformat"
        case .aiPostProcessing: return "wand.and.stars"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

struct WarningBanner: View {
    let message: String
    let buttonTitle: String
    let action: () -> Void
    var tone: DS.Tone = .warning

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tone.icon)
            Text(message)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(tone.text)
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.dsSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tone.fill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tone.border)
                .frame(height: 1)
        }
    }
}

struct MainWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        HStack(spacing: 0) {
            SidebarView(selectedPage: $appState.selectedPage)

            VStack(spacing: 0) {
                if !appState.permissions.accessibilityGranted {
                    WarningBanner(
                        message: "Accessibility permission is required for keyboard shortcuts.",
                        buttonTitle: "Grant Permission"
                    ) {
                        appState.permissions.promptForAccessibility()
                    }
                }

                if !appState.activeEngine.isReady && !appState.isPreparingEngine {
                    WarningBanner(
                        message: appState.settings.engineChoice == .appleSpeech
                            ? "Apple Speech needs to finish its on-device setup before you can dictate."
                            : "A speech model is required to start dictating. Download one now.",
                        buttonTitle: "Set Up"
                    ) {
                        appState.selectedPage = .models
                    }
                }

                if let speechWarningMessage {
                    WarningBanner(
                        message: speechWarningMessage,
                        buttonTitle: "Set Up"
                    ) {
                        appState.selectedPage = .speechOutput
                    }
                }

                detailView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.bgWindow)
        .preferredColorScheme(.light)
        .frame(
            minWidth: MainWindowSizing.minimumWidth,
            maxWidth: .infinity,
            minHeight: MainWindowSizing.minimumHeight,
            maxHeight: .infinity
        )
    }

    private var speechWarningMessage: String? {
        guard appState.selectedPage != .readAloud else { return nil }

        let settings = appState.settings
        let configuration = SpeechOutputConfiguration(settings: settings)
        let isModelDownloaded = appState.speechModelManager.isDownloaded(
            settings.speechSynthesisModel
        )
        return SpeechReadinessWarning.message(
            for: settings.speechSynthesisModel,
            isReady: configuration.isReady,
            isModelDownloaded: isModelDownloaded
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedPage {
        case .models:
            ModelsView()
        case .speechOutput:
            SpeechModelsView()
        case .readAloud:
            ReadAloudView()
        case .settings:
            SettingsView()
        case .shortcuts:
            ShortcutsView()
        case .voiceAssistant:
            VoiceAssistantView()
        case .conversationMemory:
            ConversationMemoryView()
        case .textOverlay:
            TextOverlayView()
        case .aiPostProcessing:
            AIPostProcessingView()
        case .history:
            DictationHistoryView()
        case .about:
            AboutView()
        }
    }
}
