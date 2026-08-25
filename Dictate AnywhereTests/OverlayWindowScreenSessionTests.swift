import XCTest
@testable import Dictate_Anywhere_Dev

/// `OverlayWindow.show` runs on every overlay update, and `AppState` drives the
/// listening waveform at roughly thirty updates a second. These tests pin the
/// wiring between that redraw loop and the display lookup: one lookup while the
/// overlay stays up, a fresh one after it hides.
@MainActor
final class OverlayWindowScreenSessionTests: XCTestCase {

    /// Stands in for the window server and the accessibility API.
    private final class SpyResolver: OverlayScreenResolving {
        var indexToResolve: Int? = 1
        private(set) var resolveCount = 0

        func visibleFrames() -> [CGRect] {
            [
                CGRect(x: 0, y: 0, width: 1920, height: 1055),
                CGRect(x: -1440, y: 0, width: 1440, height: 875),
            ]
        }

        func resolveScreenIndex() -> Int? {
            resolveCount += 1
            return indexToResolve
        }
    }

    private var resolver: SpyResolver!
    private var overlay: OverlayWindow!

    override func setUp() {
        super.setUp()
        resolver = SpyResolver()
        overlay = OverlayWindow(screenResolver: resolver)
    }

    override func tearDown() {
        overlay.hide(afterDelay: 0)
        overlay = nil
        resolver = nil
        super.tearDown()
    }

    private func showListening(updates: Int) {
        for update in 0..<updates {
            overlay.show(state: .listening(level: Float(update % 10) / 10, transcript: ""))
        }
    }

    func testRepeatedListeningUpdatesResolveTheDisplayOnce() {
        showListening(updates: 30)

        XCTAssertEqual(resolver.resolveCount, 1)
    }

    /// One dictation walks through several states without hiding in between;
    /// the overlay must not re-pick its display partway through.
    func testStateChangesWithinOneSessionKeepTheSameDisplay() {
        overlay.show(state: .listening(level: 0.2, transcript: "hello"))
        overlay.show(state: .processing)
        overlay.show(state: .success)

        XCTAssertEqual(resolver.resolveCount, 1)
    }

    func testHidingTheOverlayStartsANewSession() {
        showListening(updates: 5)
        overlay.hide(afterDelay: 0)

        showListening(updates: 5)

        XCTAssertEqual(resolver.resolveCount, 2)
    }

    func testEachDictationResolvesTheDisplayExactlyOnce() {
        for _ in 0..<3 {
            showListening(updates: 10)
            overlay.show(state: .processing)
            overlay.hide(afterDelay: 0)
        }

        XCTAssertEqual(resolver.resolveCount, 3)
    }
}
