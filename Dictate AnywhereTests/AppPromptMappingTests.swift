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

    // MARK: - Settings persistence & CRUD

    private var savedAppPromptMappings: [AppPromptMapping] = []
    private var savedAppPromptMappingEnabled = false

    override func setUp() {
        super.setUp()
        let settings = Settings.shared
        savedAppPromptMappings = settings.appPromptMappings
        savedAppPromptMappingEnabled = settings.appPromptMappingEnabled
    }

    override func tearDown() {
        let settings = Settings.shared
        settings.appPromptMappings = savedAppPromptMappings
        settings.appPromptMappingEnabled = savedAppPromptMappingEnabled
        super.tearDown()
    }

    func testMappingsPersistToUserDefaults() throws {
        let settings = Settings.shared
        let entry = mapping(bundleIdentifier: "com.apple.mail", appName: "Mail", prompt: "Be formal.")
        settings.appPromptMappings = [entry]
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "appPromptMappings"))
        XCTAssertEqual(Settings.resolvedAppPromptMappings(from: data), [entry])
    }

    func testAddAppPromptMappingAppendsNewEntry() {
        let settings = Settings.shared
        settings.appPromptMappings = []
        let added = settings.addAppPromptMapping(bundleIdentifier: "com.apple.mail", appName: "Mail")
        XCTAssertEqual(added?.bundleIdentifier, "com.apple.mail")
        XCTAssertEqual(added?.prompt, "")
        XCTAssertEqual(settings.appPromptMappings.map(\.bundleIdentifier), ["com.apple.mail"])
    }

    func testAddAppPromptMappingRejectsDuplicateBundleIdentifier() {
        let settings = Settings.shared
        settings.appPromptMappings = [mapping(bundleIdentifier: "com.apple.mail")]
        let added = settings.addAppPromptMapping(bundleIdentifier: "com.apple.mail", appName: "Mail")
        XCTAssertNil(added)
        XCTAssertEqual(settings.appPromptMappings.count, 1)
    }

    func testUpdateAppPromptMappingReplacesPromptText() {
        let settings = Settings.shared
        let entry = mapping()
        settings.appPromptMappings = [entry]
        var updated = entry
        updated.prompt = "New prompt."
        settings.updateAppPromptMapping(updated)
        XCTAssertEqual(settings.appPromptMappings.first?.prompt, "New prompt.")
    }

    func testRemoveAppPromptMappingDeletesEntry() {
        let settings = Settings.shared
        let entry = mapping()
        settings.appPromptMappings = [entry]
        settings.removeAppPromptMapping(id: entry.id)
        XCTAssertTrue(settings.appPromptMappings.isEmpty)
    }
}
