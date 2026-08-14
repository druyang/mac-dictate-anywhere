import XCTest
@testable import Dictate_Anywhere_Dev

/// Pure resolution tests — no Settings.shared mutation, no snapshot needed.
final class AppPromptResolverTests: XCTestCase {
    private func mapping(
        bundleIdentifier: String = "com.apple.mail",
        prompt: String = "Be formal."
    ) -> AppPromptMapping {
        AppPromptMapping(id: UUID(), bundleIdentifier: bundleIdentifier, appName: "Mail", prompt: prompt)
    }

    func testExactMatchReturnsMappedPrompt() {
        let resolved = AppPromptResolver.resolve(
            bundleIdentifier: "com.apple.mail",
            mappings: [mapping()],
            enabled: true,
            fallback: "Default prompt."
        )
        XCTAssertEqual(resolved, "Be formal.")
    }

    func testNoMatchReturnsFallback() {
        let resolved = AppPromptResolver.resolve(
            bundleIdentifier: "com.example.unmapped",
            mappings: [mapping()],
            enabled: true,
            fallback: "Default prompt."
        )
        XCTAssertEqual(resolved, "Default prompt.")
    }

    func testDisabledReturnsFallbackEvenWithMatch() {
        let resolved = AppPromptResolver.resolve(
            bundleIdentifier: "com.apple.mail",
            mappings: [mapping()],
            enabled: false,
            fallback: "Default prompt."
        )
        XCTAssertEqual(resolved, "Default prompt.")
    }

    func testNilBundleIdentifierReturnsFallback() {
        let resolved = AppPromptResolver.resolve(
            bundleIdentifier: nil,
            mappings: [mapping()],
            enabled: true,
            fallback: "Default prompt."
        )
        XCTAssertEqual(resolved, "Default prompt.")
    }

    func testEmptyMappingsReturnsFallback() {
        let resolved = AppPromptResolver.resolve(
            bundleIdentifier: "com.apple.mail",
            mappings: [],
            enabled: true,
            fallback: "Default prompt."
        )
        XCTAssertEqual(resolved, "Default prompt.")
    }
}
