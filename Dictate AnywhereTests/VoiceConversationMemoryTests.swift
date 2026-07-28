import Foundation
import XCTest
@testable import Dictate_Anywhere_Dev

@MainActor
final class VoiceConversationMemoryTests: XCTestCase {
    func testStorePrunesOldestCompletedExchangesAtConfiguredCap() throws {
        let store = try VoiceConversationStore(isStoredInMemoryOnly: true)

        for index in 0..<7 {
            try store.appendCompletedExchange(
                userMessage: "user-\(index)",
                assistantMessage: "assistant-\(index)",
                scope: .general,
                provider: .appleIntelligence,
                model: "system-language-model",
                limit: 5,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let exchanges = try store.exchanges(in: .general, limit: 100)
        XCTAssertEqual(exchanges.map(\.userMessage), [
            "user-2",
            "user-3",
            "user-4",
            "user-5",
            "user-6",
        ])
        XCTAssertEqual(try store.countAll(), 5)
    }

    func testStoreKeepsGeneralAndCodexProjectMemoryIsolated() throws {
        let store = try VoiceConversationStore(isStoredInMemoryOnly: true)

        try store.appendCompletedExchange(
            userMessage: "General question",
            assistantMessage: "General answer",
            scope: .general,
            provider: .ollama,
            model: "gemma",
            limit: 20
        )
        try store.appendCompletedExchange(
            userMessage: "Project A question",
            assistantMessage: "Project A answer",
            scope: .codex(workspacePath: "/tmp/project-a"),
            provider: nil,
            model: "codex",
            limit: 20
        )
        try store.appendCompletedExchange(
            userMessage: "Project B question",
            assistantMessage: "Project B answer",
            scope: .codex(workspacePath: "/tmp/project-b"),
            provider: nil,
            model: "codex",
            limit: 20
        )

        XCTAssertEqual(
            try store.exchanges(in: .general, limit: 20).map(\.userMessage),
            ["General question"]
        )
        XCTAssertEqual(
            try store.exchanges(
                in: .codex(workspacePath: "/tmp/project-a"),
                limit: 20
            ).map(\.userMessage),
            ["Project A question"]
        )
        XCTAssertEqual(
            try store.exchanges(
                in: .codex(workspacePath: "/tmp/project-b"),
                limit: 20
            ).map(\.userMessage),
            ["Project B question"]
        )
    }

    func testLoweringCapPrunesEveryConversationScope() throws {
        let store = try VoiceConversationStore(isStoredInMemoryOnly: true)
        let scopes: [VoiceConversationScope] = [
            .general,
            .codex(workspacePath: "/tmp/project"),
        ]

        for scope in scopes {
            for index in 0..<8 {
                try store.appendCompletedExchange(
                    userMessage: "\(scope.storageKey)-user-\(index)",
                    assistantMessage: "answer-\(index)",
                    scope: scope,
                    provider: scope == .general ? .openRouter : nil,
                    model: "test",
                    limit: 100,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            }
        }

        try store.pruneAll(to: 5)

        for scope in scopes {
            let exchanges = try store.exchanges(in: scope, limit: 100)
            XCTAssertEqual(exchanges.count, 5)
            XCTAssertTrue(exchanges.first?.userMessage.hasSuffix("user-3") == true)
            XCTAssertTrue(exchanges.last?.userMessage.hasSuffix("user-7") == true)
        }
    }

    func testPersistentStoreSurvivesContainerReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let storeURL = directory.appendingPathComponent("memory.store")

        do {
            let store = try VoiceConversationStore(storeURL: storeURL)
            try store.appendCompletedExchange(
                userMessage: "Remember this",
                assistantMessage: "I will",
                scope: .general,
                provider: .appleIntelligence,
                model: "system-language-model",
                limit: 20
            )
        }

        do {
            let reopenedStore = try VoiceConversationStore(storeURL: storeURL)
            let exchanges = try reopenedStore.exchanges(in: .general, limit: 20)
            XCTAssertEqual(exchanges.map(\.userMessage), ["Remember this"])
            XCTAssertEqual(exchanges.map(\.assistantMessage), ["I will"])
        }
    }

    func testContextBudgetKeepsNewestWholeExchangesInChronologicalOrder() {
        let exchanges = (0..<3).map { index in
            VoiceConversationExchange(
                id: UUID(),
                userMessage: "u\(index)",
                assistantMessage: "a\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                provider: .ollama,
                model: "test"
            )
        }

        let selected = VoiceConversationContext.newestExchanges(
            from: exchanges,
            fittingCharacterBudget: 72
        )

        XCTAssertEqual(selected.map(\.userMessage), ["u1", "u2"])
        XCTAssertEqual(
            VoiceConversationContext.messages(from: selected).map(\.role),
            [.user, .assistant, .user, .assistant]
        )
    }

    func testEmptyOrIncompleteExchangeIsNotPersisted() throws {
        let store = try VoiceConversationStore(isStoredInMemoryOnly: true)

        try store.appendCompletedExchange(
            userMessage: "Question",
            assistantMessage: " ",
            scope: .general,
            provider: .ollama,
            model: "test",
            limit: 20
        )

        XCTAssertEqual(try store.countAll(), 0)
    }

    func testAllEntriesIncludesScopeAndUsesNewestFirstOrder() throws {
        let store = try VoiceConversationStore(isStoredInMemoryOnly: true)
        try store.appendCompletedExchange(
            userMessage: "Older general question",
            assistantMessage: "Older answer",
            scope: .general,
            provider: .ollama,
            model: "gemma",
            limit: 20,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try store.appendCompletedExchange(
            userMessage: "Newer project question",
            assistantMessage: "Newer answer",
            scope: .codex(workspacePath: "/tmp/project"),
            provider: nil,
            model: "codex",
            limit: 20,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        let entries = try store.allEntries()

        XCTAssertEqual(entries.map(\.userMessage), [
            "Newer project question",
            "Older general question",
        ])
        XCTAssertEqual(entries.map(\.scope), [
            .codex(workspacePath: "/tmp/project"),
            .general,
        ])
    }

    func testDeletingIndividualEntryKeepsOtherMemories() throws {
        let store = try VoiceConversationStore(isStoredInMemoryOnly: true)
        for index in 0..<3 {
            try store.appendCompletedExchange(
                userMessage: "question-\(index)",
                assistantMessage: "answer-\(index)",
                scope: .general,
                provider: .appleIntelligence,
                model: "system-language-model",
                limit: 20,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let entryToDelete = try XCTUnwrap(
            store.allEntries().first { $0.userMessage == "question-1" }
        )

        XCTAssertTrue(try store.deleteExchange(id: entryToDelete.id))
        XCTAssertFalse(try store.deleteExchange(id: entryToDelete.id))
        XCTAssertEqual(
            try store.exchanges(in: .general, limit: 20).map(\.userMessage),
            ["question-0", "question-2"]
        )
        XCTAssertEqual(try store.countAll(), 2)
    }

    func testMemorySearchMatchesMessagesAndProjectScope() {
        let generalEntry = VoiceConversationMemoryEntry(
            exchange: VoiceConversationExchange(
                id: UUID(),
                userMessage: "Plan my afternoon",
                assistantMessage: "Start with the design review",
                createdAt: Date(),
                provider: .openRouter,
                model: "test-model"
            ),
            scope: .general
        )
        let codexEntry = VoiceConversationMemoryEntry(
            exchange: VoiceConversationExchange(
                id: UUID(),
                userMessage: "What changed?",
                assistantMessage: "Two Swift files changed",
                createdAt: Date(),
                provider: nil,
                model: "codex"
            ),
            scope: .codex(workspacePath: "/tmp/sample-project")
        )
        let entries = [generalEntry, codexEntry]

        XCTAssertEqual(
            ConversationMemoryView.filteredEntries(entries, searchText: "design").map(\.id),
            [generalEntry.id]
        )
        XCTAssertEqual(
            ConversationMemoryView.filteredEntries(entries, searchText: "sample-project").map(\.id),
            [codexEntry.id]
        )
    }
}
