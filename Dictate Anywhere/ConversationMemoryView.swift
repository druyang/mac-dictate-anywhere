//
//  ConversationMemoryView.swift
//  Dictate Anywhere
//
//  Voice Assistant conversation-memory settings and saved exchanges.
//

import Foundation
import SwiftUI

struct ConversationMemoryView: View {
    @Environment(AppState.self) private var appState

    @State private var searchText = ""
    @State private var showClearAllConfirmation = false
    @State private var pendingDeletion: VoiceConversationMemoryEntry?
    @State private var showDeleteConfirmation = false

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        return formatter
    }()

    static func filteredEntries(
        _ entries: [VoiceConversationMemoryEntry],
        searchText: String
    ) -> [VoiceConversationMemoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }

        return entries.filter { entry in
            let searchableText = [
                entry.userMessage,
                entry.assistantMessage,
                scopeTitle(for: entry),
                scopeDetail(for: entry),
                entry.model,
            ].joined(separator: "\n")
            return searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    static func scopeTitle(for entry: VoiceConversationMemoryEntry) -> String {
        switch entry.scope {
        case .general:
            return "Voice Assistant"
        case .codex(let workspacePath):
            let projectName = URL(fileURLWithPath: workspacePath).lastPathComponent
            return projectName.isEmpty ? "Codex" : "Codex · \(projectName)"
        }
    }

    static func scopeDetail(for entry: VoiceConversationMemoryEntry) -> String {
        switch entry.scope {
        case .general:
            let providerName = entry.provider?.displayName ?? "Voice Assistant"
            return entry.model.isEmpty ? providerName : "\(providerName) · \(entry.model)"
        case .codex(let workspacePath):
            return workspacePath
        }
    }

    var body: some View {
        @Bindable var settings = appState.settings
        let entries = Self.filteredEntries(
            appState.agentMemoryEntries,
            searchText: searchText
        )

        DSPage(spacing: 20) {
            DSSectionHeader(
                title: "Conversation Memory",
                subtitle: "Control and review what the Voice Assistant remembers."
            )

            memoryConfiguration(settings: settings)

            DSPanel(
                text: "Memory is stored locally. When OpenRouter or a remote Ollama server answers, the relevant saved exchanges are sent to that provider.",
                tone: .neutral,
                icon: "lock"
            )

            HStack(spacing: 10) {
                DSSearchField(
                    placeholder: "Search saved conversations",
                    text: $searchText
                )
                Button("Clear All…") {
                    showClearAllConfirmation = true
                }
                .buttonStyle(.dsDestructive)
                .disabled(appState.agentMemoryEntries.isEmpty)
            }

            if entries.isEmpty {
                emptyState
            } else {
                DSCard {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            DSDivider()
                        }
                        ConversationMemoryRow(entry: entry) {
                            pendingDeletion = entry
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
        }
        .task {
            appState.refreshAgentMemoryStatus(pruneToCurrentLimit: true)
        }
        .alert("Clear conversation memory?", isPresented: $showClearAllConfirmation) {
            Button("Clear All", role: .destructive) {
                appState.clearAgentConversationMemory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved Voice Assistant and project-specific Codex exchange from this Mac.")
        }
        .alert(
            "Delete this memory?",
            isPresented: $showDeleteConfirmation,
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                appState.deleteAgentConversationMemory(id: entry.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { entry in
            Text("This permanently removes the exchange from \(Self.scopeTitle(for: entry)) and future assistant context.")
        }
    }

    private func memoryConfiguration(settings: Settings) -> some View {
        DSSection(overline: "Memory Settings") {
            DSStackedRow(
                label: "Remember conversations",
                caption: "Save completed exchanges and include recent ones with future requests. Turning this off keeps existing memories but stops using or adding to them.",
                isOn: Binding(
                    get: { settings.agentConversationMemoryEnabled },
                    set: { settings.agentConversationMemoryEnabled = $0 }
                )
            )

            DSDivider()

            DSDetailRow(
                label: "Memory limit",
                caption: "Keep this many exchanges per conversation scope. Lowering the limit permanently removes the oldest entries."
            ) {
                Stepper(
                    value: Binding(
                        get: { settings.agentMemoryExchangeLimit },
                        set: { appState.setAgentMemoryExchangeLimit($0) }
                    ),
                    in: Settings.agentMemoryExchangeLimitRange
                ) {
                    Text("\(settings.agentMemoryExchangeLimit) exchanges")
                        .font(DS.Fonts.ui(12.5, .semibold))
                        .foregroundStyle(DS.Colors.ink)
                        .frame(minWidth: 92, alignment: .trailing)
                }
                .fixedSize()
            }

            DSDivider()

            HStack {
                Text(
                    appState.agentMemoryExchangeCount == 1
                        ? "1 saved exchange"
                        : "\(appState.agentMemoryExchangeCount) saved exchanges"
                )
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, DS.Spacing.rowHorizontal)

            if let storageError = appState.agentMemoryStorageError {
                DSDivider()
                DSPanel(text: storageError, tone: .danger)
                    .padding(DS.Spacing.rowHorizontal)
            }
        }
    }

    private var emptyState: some View {
        DSCard {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 26))
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(searchText.isEmpty ? "No Saved Conversations" : "No Matches")
                    .font(DS.Fonts.ui(14, .semibold))
                    .foregroundStyle(DS.Colors.ink)
                Text(
                    searchText.isEmpty
                        ? "Completed Voice Assistant exchanges will appear here when memory is enabled."
                        : "No saved conversations match “\(searchText)”."
                )
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
        }
    }
}

struct ConversationMemoryRow: View {
    let entry: VoiceConversationMemoryEntry
    let onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(ConversationMemoryView.dateFormatter.string(from: entry.createdAt))
                        .font(DS.Fonts.ui(11.5, .semibold))
                        .tracking(0.2)
                        .foregroundStyle(DS.Colors.textSecondary)
                    DSStatusPill(
                        text: ConversationMemoryView.scopeTitle(for: entry),
                        tone: .neutral
                    )
                }

                Text(ConversationMemoryView.scopeDetail(for: entry))
                    .font(DS.Fonts.ui(11.5))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ConversationMemoryView.scopeDetail(for: entry))

                conversationMessage(label: "You", text: entry.userMessage)
                conversationMessage(label: "Assistant", text: entry.assistantMessage)

                if shouldOfferExpansion {
                    Button(isExpanded ? "Show Less" : "Show Full Exchange") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.ui(12, .semibold))
                    .foregroundStyle(DS.Colors.accent)
                }
            }

            DSIconButton(
                systemImage: "trash",
                tint: DS.Colors.destructive,
                accessibilityLabel: "Delete conversation memory",
                action: onDelete
            )
            .help("Delete conversation memory")
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    private func conversationMessage(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(DS.Fonts.ui(10.5, .semibold))
                .tracking(0.5)
                .foregroundStyle(DS.Colors.textSecondary)
            Text(text)
                .font(DS.Fonts.ui(13.5))
                .foregroundStyle(DS.Colors.ink)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shouldOfferExpansion: Bool {
        entry.userMessage.count + entry.assistantMessage.count > 700
            || entry.userMessage.filter(\.isNewline).count
                + entry.assistantMessage.filter(\.isNewline).count > 10
    }
}
