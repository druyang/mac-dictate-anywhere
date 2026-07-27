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
        isReady: Bool
    ) -> String? {
        guard !isReady else { return nil }

        if model.isLocal {
            return "\(model.displayName) isn’t downloaded. Download it before the Voice Assistant can speak responses."
        }

        return "OpenRouter speech isn’t ready. Add the shared API key, then choose a speech model and voice."
    }
}

enum SidebarPage: String, CaseIterable, Identifiable {
    case models
    case speechOutput
    case settings
    case shortcuts
    case voiceAssistant
    case textOverlay
    case aiPostProcessing
    case history
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "Dictation Model"
        case .speechOutput: return "Speech Model"
        case .settings: return "General"
        case .shortcuts: return "Shortcuts"
        case .voiceAssistant: return "Voice Assistant"
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
        case .settings: return "slider.horizontal.3"
        case .shortcuts: return "command"
        case .voiceAssistant: return "waveform.and.mic"
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
        let settings = appState.settings
        let configuration = SpeechOutputConfiguration(settings: settings)
        let isReady = settings.speechSynthesisModel.isLocal
            ? appState.speechModelManager.isDownloaded(settings.speechSynthesisModel)
            : configuration.isReady
        return SpeechReadinessWarning.message(
            for: settings.speechSynthesisModel,
            isReady: isReady
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedPage {
        case .models:
            ModelsView()
        case .speechOutput:
            SpeechModelsView()
        case .settings:
            SettingsView()
        case .shortcuts:
            ShortcutsView()
        case .voiceAssistant:
            VoiceAssistantView()
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
