//
//  AppPromptSettingsSection.swift
//  Dictate Anywhere
//
//  "App Prompts" section of Transcript Cleanup settings: opt-in toggle plus
//  per-app cleanup-prompt rows, matched against the frontmost app's bundle
//  identifier at dictation time. One prompt per app, used by whichever
//  post-processing provider is currently active.
//

import SwiftUI
import AppKit

struct AppPromptSettingsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        let runningApps = Self.runningApps()

        VStack(alignment: .leading, spacing: DS.Spacing.section) {
            DSSection(overline: "App Prompts") {
                DSStackedRow(
                    label: "Use per-app prompts",
                    caption: "When dictating into a matched app, use that app's prompt instead of the prompt above.",
                    isOn: $settings.appPromptMappingEnabled
                )
                if settings.appPromptMappingEnabled {
                    ForEach(settings.appPromptMappings) { mapping in
                        DSDivider()
                        AppPromptMappingRow(
                            mapping: mapping,
                            runningApps: runningApps,
                            takenBundleIdentifiers: Set(
                                settings.appPromptMappings
                                    .filter { $0.id != mapping.id }
                                    .map(\.bundleIdentifier)
                            )
                        )
                    }
                }
            }

            if settings.appPromptMappingEnabled, canAddMapping(runningApps: runningApps) {
                DSAddButton(title: "Add App") { addMapping(runningApps: runningApps) }
            }
        }
    }

    private func canAddMapping(runningApps: [RunningAppInfo]) -> Bool {
        let taken = Set(appState.settings.appPromptMappings.map(\.bundleIdentifier))
        return runningApps.contains { !taken.contains($0.bundleIdentifier) }
    }

    private func addMapping(runningApps: [RunningAppInfo]) {
        let settings = appState.settings
        let taken = Set(settings.appPromptMappings.map(\.bundleIdentifier))
        guard let app = runningApps.first(where: { !taken.contains($0.bundleIdentifier) }) else { return }
        settings.addAppPromptMapping(bundleIdentifier: app.bundleIdentifier, appName: app.localizedName)
    }

    /// Currently-running regular UI apps, excluding Dictate Anywhere itself.
    /// Not unit-tested: `NSRunningApplication` has no public initializer, so
    /// this thin OS-integration read is verified by the manual checklist,
    /// same as the frontmost-app capture in `AppState.captureInsertionTargetApp()`.
    static func runningApps() -> [RunningAppInfo] {
        let selfBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != nil && $0.bundleIdentifier != selfBundleID }
            .map { RunningAppInfo(bundleIdentifier: $0.bundleIdentifier!, localizedName: $0.localizedName ?? $0.bundleIdentifier!) }
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
    }
}

/// Lightweight, testable stand-in for the fields this feature needs off
/// `NSRunningApplication`.
struct RunningAppInfo: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let localizedName: String
}

// MARK: - Mapping Row

private struct AppPromptMappingRow: View {
    @Environment(AppState.self) private var appState
    let mapping: AppPromptMapping
    let runningApps: [RunningAppInfo]
    let takenBundleIdentifiers: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSInfoRow(label: "App") {
                HStack(spacing: 10) {
                    DSDropdown(
                        selection: bundleIdentifierBinding,
                        options: bundleIdentifierOptions,
                        title: { appName(for: $0) }
                    )
                    DSIconButton(
                        systemImage: "trash",
                        accessibilityLabel: "Delete app prompt"
                    ) {
                        appState.settings.removeAppPromptMapping(id: mapping.id)
                    }
                }
            }
            cardPadded {
                SettingsMultilineTextArea(
                    text: promptBinding,
                    placeholder: "Enter a prompt for this app…",
                    minHeight: 60
                )
            }
        }
    }

    /// The current app's bundle identifier plus every running,
    /// not-already-mapped app — mirrors `InputSourceMappingRow.sourceOptions`.
    private var bundleIdentifierOptions: [String] {
        var ids = runningApps.map(\.bundleIdentifier).filter { !takenBundleIdentifiers.contains($0) }
        if !ids.contains(mapping.bundleIdentifier) {
            ids.insert(mapping.bundleIdentifier, at: 0)
        }
        return ids
    }

    private func appName(for bundleIdentifier: String) -> String {
        if let app = runningApps.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return app.localizedName
        }
        // App no longer running; show the cached name.
        return "\(mapping.appName) (not running)"
    }

    private var bundleIdentifierBinding: Binding<String> {
        Binding(
            get: { mapping.bundleIdentifier },
            set: { newBundleIdentifier in
                var updated = mapping
                updated.bundleIdentifier = newBundleIdentifier
                if let app = runningApps.first(where: { $0.bundleIdentifier == newBundleIdentifier }) {
                    updated.appName = app.localizedName
                }
                appState.settings.updateAppPromptMapping(updated)
            }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { mapping.prompt },
            set: { newPrompt in
                var updated = mapping
                updated.prompt = newPrompt
                appState.settings.updateAppPromptMapping(updated)
            }
        )
    }

    @ViewBuilder
    private func cardPadded<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }
}
