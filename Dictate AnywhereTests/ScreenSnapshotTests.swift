import XCTest
import SwiftUI
@testable import Dictate_Anywhere_Dev

/// Renders every page inside the full window chrome at the design canvas size
/// (1120×780). Asserts the render succeeds and writes PNGs to the temporary
/// directory for visual inspection (path printed in the test log).
@MainActor
final class ScreenSnapshotTests: XCTestCase {

    private static let outputDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictateAnywhereScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func renderWindow(
        page: SidebarPage,
        variant: String? = nil,
        configure: (AppState) -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let appState = AppState()
        appState.selectedPage = page
        configure(appState)

        let view = MainWindow()
            .environment(appState)
            .frame(width: MainWindowSizing.defaultWidth, height: MainWindowSizing.defaultHeight)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage else {
            XCTFail("\(page.title) failed to render", file: file, line: line)
            return
        }
        XCTAssertEqual(image.size.width, MainWindowSizing.defaultWidth, accuracy: 1, file: file, line: line)
        XCTAssertEqual(image.size.height, MainWindowSizing.defaultHeight, accuracy: 1, file: file, line: line)

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let name = variant.map { "\(page.rawValue)-\($0)" } ?? page.rawValue
            let url = Self.outputDirectory.appendingPathComponent("\(name).png")
            try? png.write(to: url)
            print("Screenshot written: \(url.path)")
        }
    }

    func testDictationModelScreenRenders() { renderWindow(page: .models) }
    /// The default model is local, so this covers the page with the cloud
    /// credentials, catalogue and cache row hidden.
    func testSpeechModelScreenRenders() { renderWindow(page: .speechOutput) }

    func testSpeechModelScreenRendersCloudConfiguration() {
        renderWindow(page: .speechOutput, variant: "openrouter") { appState in
            appState.settings.speechSynthesisModel = .openRouter
        }
    }
    func testReadAloudScreenRenders() { renderWindow(page: .readAloud) }

    /// The reader is a different surface from the empty state: word canvas,
    /// highlight and player bar.
    func testReadAloudReaderRenders() {
        renderWindow(page: .readAloud, variant: "reader") { appState in
            appState.readAloudText = """
            Feasibility Assessment

            The demand is real and growing fast, the pricing supports a good living, \
            and twenty years of engineering depth place this founder in a genuinely \
            underserved band above the crowded no-code end of the market.

            The better entry point is small and mid-sized businesses in one vertical \
            he already understands, not broad solopreneurs. Solopreneurs mostly run on \
            free tiers and rarely pay for implementation, while SMBs have budget, real \
            workflow pain, and a documented willingness to trust an outside advisor.
            """
            appState.seekReadAloud(toWordIndex: 40)
        }
    }
    func testGeneralScreenRenders() { renderWindow(page: .settings) }
    func testShortcutsScreenRenders() { renderWindow(page: .shortcuts) }
    func testVoiceAssistantScreenRenders() { renderWindow(page: .voiceAssistant) }
    func testConversationMemoryScreenRenders() { renderWindow(page: .conversationMemory) }
    func testTextOverlayScreenRenders() { renderWindow(page: .textOverlay) }
    func testTranscriptCleanupScreenRenders() { renderWindow(page: .aiPostProcessing) }
    func testDictationHistoryScreenRenders() { renderWindow(page: .history) }
    func testAboutScreenRenders() { renderWindow(page: .about) }
}
