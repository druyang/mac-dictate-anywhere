import XCTest
@testable import Dictate_Anywhere_Dev

final class AppPromptMappingTests: XCTestCase {
    private func mapping(
        bundleIdentifier: String = "com.example.app",
        appName: String = "Example",
        prompt: String = "Be casual."
    ) -> AppPromptMapping {
        AppPromptMapping(id: UUID(), bundleIdentifier: bundleIdentifier, appName: appName, prompt: prompt)
    }

    func testMappingRoundTripsThroughJSON() throws {
        let mappings = [
            mapping(),
            mapping(bundleIdentifier: "com.apple.mail", appName: "Mail", prompt: "Be formal."),
        ]
        let data = try JSONEncoder().encode(mappings)
        XCTAssertEqual(Settings.resolvedAppPromptMappings(from: data), mappings)
    }

    func testResolvedMappingsReturnsPreloadedSeedWhenDataIsNil() {
        XCTAssertEqual(Settings.resolvedAppPromptMappings(from: nil), Settings.preloadedAppPromptMappings)
    }

    func testResolvedMappingsReturnsEmptyArrayWhenStoredExplicitlyEmpty() throws {
        let data = try JSONEncoder().encode([AppPromptMapping]())
        XCTAssertEqual(Settings.resolvedAppPromptMappings(from: data), [])
    }

    func testResolvedMappingsReturnsEmptyOnGarbageData() {
        XCTAssertTrue(Settings.resolvedAppPromptMappings(from: Data("not json".utf8)).isEmpty)
    }

    func testPreloadedMappingsCoverExpectedApps() {
        let bundleIDs = Set(Settings.preloadedAppPromptMappings.map(\.bundleIdentifier))
        XCTAssertEqual(bundleIDs, [
            "com.apple.MobileSMS",
            "com.tinyspeck.slackmacgap",
            "com.apple.mail",
            "com.microsoft.VSCode",
        ])
    }

    func testPreloadedMappingsHaveUniqueIDs() {
        let ids = Settings.preloadedAppPromptMappings.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
