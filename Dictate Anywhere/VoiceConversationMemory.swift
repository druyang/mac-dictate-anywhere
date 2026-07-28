//
//  VoiceConversationMemory.swift
//  Dictate Anywhere
//
//  Provider-neutral, versioned conversation memory stored outside the app bundle.
//

import Foundation
import SwiftData

enum VoiceConversationScope: Hashable, Sendable {
    case general
    case codex(workspacePath: String)

    nonisolated init?(storageKey: String) {
        if storageKey == "general" {
            self = .general
            return
        }

        let codexPrefix = "codex:"
        guard storageKey.hasPrefix(codexPrefix) else { return nil }
        let workspacePath = String(storageKey.dropFirst(codexPrefix.count))
        guard !workspacePath.isEmpty else { return nil }
        self = .codex(workspacePath: workspacePath)
    }

    nonisolated var storageKey: String {
        switch self {
        case .general:
            return "general"
        case .codex(let workspacePath):
            let normalizedPath = URL(fileURLWithPath: workspacePath)
                .standardizedFileURL
                .path
            return "codex:\(normalizedPath)"
        }
    }
}

struct VoiceConversationMemoryEntry: Identifiable, Equatable, Sendable {
    let exchange: VoiceConversationExchange
    let scope: VoiceConversationScope

    nonisolated var id: UUID { exchange.id }
    nonisolated var userMessage: String { exchange.userMessage }
    nonisolated var assistantMessage: String { exchange.assistantMessage }
    nonisolated var createdAt: Date { exchange.createdAt }
    nonisolated var provider: AgentBrainProvider? { exchange.provider }
    nonisolated var model: String { exchange.model }
}

struct VoiceConversationExchange: Equatable, Sendable {
    let id: UUID
    let userMessage: String
    let assistantMessage: String
    let createdAt: Date
    let provider: AgentBrainProvider?
    let model: String

    nonisolated var characterCount: Int {
        userMessage.count + assistantMessage.count
    }
}

enum VoiceAgentMessageRole: String, Equatable, Sendable {
    case user
    case assistant
}

struct VoiceAgentMessage: Equatable, Sendable {
    let role: VoiceAgentMessageRole
    let content: String
}

enum VoiceConversationContext {
    /// Leaves room for the current request, system instructions, and response.
    nonisolated static let appleIntelligenceCharacterBudget = 12_000
    nonisolated static let ollamaCharacterBudget = 24_000
    nonisolated static let openRouterCharacterBudget = 40_000
    nonisolated static let codexCharacterBudget = 40_000

    nonisolated static func messages(from exchanges: [VoiceConversationExchange]) -> [VoiceAgentMessage] {
        exchanges.flatMap { exchange in
            [
                VoiceAgentMessage(role: .user, content: exchange.userMessage),
                VoiceAgentMessage(role: .assistant, content: exchange.assistantMessage),
            ]
        }
    }

    nonisolated static func newestExchanges(
        from exchanges: [VoiceConversationExchange],
        fittingCharacterBudget budget: Int
    ) -> [VoiceConversationExchange] {
        guard budget > 0 else { return [] }

        var selected: [VoiceConversationExchange] = []
        var usedCharacters = 0

        for exchange in exchanges.reversed() {
            // Account for role labels and message framing used by providers.
            let exchangeCost = exchange.characterCount + 32
            guard usedCharacters + exchangeCost <= budget else { break }
            selected.append(exchange)
            usedCharacters += exchangeCost
        }

        return selected.reversed()
    }

    nonisolated static func characterBudget(for provider: AgentBrainProvider) -> Int {
        switch provider {
        case .appleIntelligence:
            return appleIntelligenceCharacterBudget
        case .ollama:
            return ollamaCharacterBudget
        case .openRouter:
            return openRouterCharacterBudget
        }
    }
}

enum VoiceMemorySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredExchange.self]
    }

    @Model
    final class StoredExchange {
        @Attribute(.unique) var id: UUID
        var scopeKey: String
        var userMessage: String
        var assistantMessage: String
        var createdAt: Date
        var providerRawValue: String?
        var model: String

        init(
            id: UUID,
            scopeKey: String,
            userMessage: String,
            assistantMessage: String,
            createdAt: Date,
            providerRawValue: String?,
            model: String
        ) {
            self.id = id
            self.scopeKey = scopeKey
            self.userMessage = userMessage
            self.assistantMessage = assistantMessage
            self.createdAt = createdAt
            self.providerRawValue = providerRawValue
            self.model = model
        }
    }
}

enum VoiceMemoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [VoiceMemorySchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

@MainActor
final class VoiceConversationStore {
    typealias StoredExchange = VoiceMemorySchemaV1.StoredExchange

    static let storeFilename = "VoiceAssistantMemory.store"

    let storeURL: URL?

    private let container: ModelContainer
    private let context: ModelContext

    init(storeURL: URL? = nil, isStoredInMemoryOnly: Bool = false) throws {
        let schema = Schema(versionedSchema: VoiceMemorySchemaV1.self)
        let configuration: ModelConfiguration

        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "VoiceAssistantMemory",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            self.storeURL = nil
        } else {
            let resolvedStoreURL = try storeURL ?? Self.defaultStoreURL()
            configuration = ModelConfiguration(
                "VoiceAssistantMemory",
                schema: schema,
                url: resolvedStoreURL,
                cloudKitDatabase: .none
            )
            self.storeURL = resolvedStoreURL
        }

        container = try ModelContainer(
            for: schema,
            migrationPlan: VoiceMemoryMigrationPlan.self,
            configurations: configuration
        )
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func exchanges(
        in scope: VoiceConversationScope,
        limit: Int
    ) throws -> [VoiceConversationExchange] {
        let scopeKey = scope.storageKey
        var descriptor = FetchDescriptor<StoredExchange>(
            predicate: #Predicate { exchange in
                exchange.scopeKey == scopeKey
            },
            sortBy: [SortDescriptor(\StoredExchange.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = Settings.clampedAgentMemoryExchangeLimit(limit)
        descriptor.fetchOffset = max(
            0,
            try count(in: scope) - Settings.clampedAgentMemoryExchangeLimit(limit)
        )
        return try context.fetch(descriptor).map(Self.snapshot)
    }

    func allEntries() throws -> [VoiceConversationMemoryEntry] {
        let descriptor = FetchDescriptor<StoredExchange>(
            sortBy: [SortDescriptor(\StoredExchange.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap { exchange in
            guard let scope = VoiceConversationScope(storageKey: exchange.scopeKey) else {
                return nil
            }
            return VoiceConversationMemoryEntry(
                exchange: Self.snapshot(exchange),
                scope: scope
            )
        }
    }

    func appendCompletedExchange(
        userMessage: String,
        assistantMessage: String,
        scope: VoiceConversationScope,
        provider: AgentBrainProvider?,
        model: String,
        limit: Int,
        createdAt: Date = Date()
    ) throws {
        let trimmedUserMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistantMessage = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserMessage.isEmpty, !trimmedAssistantMessage.isEmpty else { return }

        context.insert(
            StoredExchange(
                id: UUID(),
                scopeKey: scope.storageKey,
                userMessage: trimmedUserMessage,
                assistantMessage: trimmedAssistantMessage,
                createdAt: createdAt,
                providerRawValue: provider?.rawValue,
                model: model
            )
        )
        try prune(scopeKey: scope.storageKey, to: limit)
        try context.save()
    }

    @discardableResult
    func deleteExchange(id: UUID) throws -> Bool {
        let exchangeID = id
        var descriptor = FetchDescriptor<StoredExchange>(
            predicate: #Predicate { exchange in
                exchange.id == exchangeID
            }
        )
        descriptor.fetchLimit = 1
        guard let exchange = try context.fetch(descriptor).first else {
            return false
        }

        context.delete(exchange)
        try context.save()
        return true
    }

    func pruneAll(to limit: Int) throws {
        let normalizedLimit = Settings.clampedAgentMemoryExchangeLimit(limit)
        let allExchanges = try context.fetch(
            FetchDescriptor<StoredExchange>(
                sortBy: [SortDescriptor(\StoredExchange.createdAt, order: .forward)]
            )
        )
        let groupedExchanges = Dictionary(grouping: allExchanges, by: \.scopeKey)
        for exchanges in groupedExchanges.values where exchanges.count > normalizedLimit {
            for exchange in exchanges.prefix(exchanges.count - normalizedLimit) {
                context.delete(exchange)
            }
        }
        if context.hasChanges {
            try context.save()
        }
    }

    func clearAll() throws {
        try context.delete(model: StoredExchange.self)
        try context.save()
    }

    func countAll() throws -> Int {
        try context.fetchCount(FetchDescriptor<StoredExchange>())
    }

    func count(in scope: VoiceConversationScope) throws -> Int {
        let scopeKey = scope.storageKey
        return try context.fetchCount(
            FetchDescriptor<StoredExchange>(
                predicate: #Predicate { exchange in
                    exchange.scopeKey == scopeKey
                }
            )
        )
    }

    private func prune(scopeKey: String, to limit: Int) throws {
        let normalizedLimit = Settings.clampedAgentMemoryExchangeLimit(limit)
        let descriptor = FetchDescriptor<StoredExchange>(
            predicate: #Predicate { exchange in
                exchange.scopeKey == scopeKey
            },
            sortBy: [SortDescriptor(\StoredExchange.createdAt, order: .forward)]
        )
        let exchanges = try context.fetch(descriptor)
        guard exchanges.count > normalizedLimit else { return }
        for exchange in exchanges.prefix(exchanges.count - normalizedLimit) {
            context.delete(exchange)
        }
    }

    private static func snapshot(_ exchange: StoredExchange) -> VoiceConversationExchange {
        VoiceConversationExchange(
            id: exchange.id,
            userMessage: exchange.userMessage,
            assistantMessage: exchange.assistantMessage,
            createdAt: exchange.createdAt,
            provider: exchange.providerRawValue.flatMap(AgentBrainProvider.init(rawValue:)),
            model: exchange.model
        )
    }

    private static func defaultStoreURL() throws -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = applicationSupportURL
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL.appendingPathComponent(storeFilename)
    }
}
