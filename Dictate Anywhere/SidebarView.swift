//
//  SidebarView.swift
//  Dictate Anywhere
//
//  Custom navigation sidebar (design-system organism).
//

import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedPage: SidebarPage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DSBrand()
                .padding(.horizontal, 6)
                .padding(.bottom, 20)

            ForEach(SidebarPage.allCases) { page in
                DSNavItem(
                    title: page.title,
                    systemImage: page.icon,
                    isSelected: selectedPage == page
                ) {
                    selectedPage = page
                }
            }

            Spacer(minLength: 0)

            DSFooterCard(
                statusText: statusText,
                statusColor: statusColor,
                versionText: "Version \(appVersion)"
            )
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .frame(width: DS.Metrics.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(DS.Colors.bgSidebar)
        .modifier(SidebarWindowDragModifier())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DS.Colors.border)
                .frame(width: 1)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var statusText: String {
        switch appState.status {
        case .idle:
            return appState.activeEngine.isReady ? "Ready to dictate" : "Model not set up"
        case .recording: return "Listening…"
        case .processing:
            if appState.isAgentRequestInProgress {
                return "Thinking and speaking…"
            }
            return appState.isSpeechOutputInProgress ? "Preparing voice…" : "Transcribing…"
        case .error: return "Something went wrong"
        }
    }

    /// Idle-not-ready → grey, working → blue, ready → green, failed → red.
    /// Work in progress is information, so it takes the info tone rather than
    /// the brand accent, which would read as an alert next to the error state.
    private var statusColor: Color {
        switch appState.status {
        case .idle:
            return appState.activeEngine.isReady ? DS.Tone.success.icon : DS.Tone.neutral.icon
        case .recording, .processing: return DS.Tone.info.icon
        case .error: return DS.Tone.danger.icon
        }
    }
}
