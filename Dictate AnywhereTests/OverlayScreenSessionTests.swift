import XCTest
@testable import Dictate_Anywhere_Dev

/// Choosing the overlay's display is expensive: it reaches across a process
/// boundary to ask the focused application where it is. The overlay redraws on
/// every state update, so that choice has to be made once per visible session
/// and reused, not repeated per frame.
///
/// The layout is a two-display desktop: the primary 1920x1080 display at the
/// origin and a 1440x900 secondary to its left, which gives the secondary the
/// negative x origin a real left-hand monitor has.
final class OverlayScreenSessionTests: XCTestCase {
    private let primaryVisibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1055)
    private let secondaryVisibleFrame = CGRect(x: -1440, y: 0, width: 1440, height: 875)

    /// Stands in for the window server and the accessibility API.
    private final class SpyResolver: OverlayScreenResolving {
        var frames: [CGRect]
        var indexToResolve: Int?
        private(set) var resolveCount = 0
        private(set) var visibleFramesCount = 0

        init(frames: [CGRect], indexToResolve: Int?) {
            self.frames = frames
            self.indexToResolve = indexToResolve
        }

        func visibleFrames() -> [CGRect] {
            visibleFramesCount += 1
            return frames
        }

        func resolveScreenIndex() -> Int? {
            resolveCount += 1
            return indexToResolve
        }
    }

    private func makeResolver(indexToResolve: Int? = 1) -> SpyResolver {
        SpyResolver(
            frames: [primaryVisibleFrame, secondaryVisibleFrame],
            indexToResolve: indexToResolve
        )
    }

    // MARK: - One lookup per session

    /// The listening waveform updates about thirty times a second. Every one of
    /// those updates repositions the overlay, and none of them may pay for a
    /// fresh cross-process lookup.
    func testResolvesTheDisplayOnceAcrossRepeatedUpdates() {
        let resolver = makeResolver()
        let session = OverlayScreenSession(resolver: resolver)

        for _ in 0..<30 {
            _ = session.visibleFrame()
        }

        XCTAssertEqual(resolver.resolveCount, 1)
    }

    func testReturnsTheVisibleFrameOfTheResolvedDisplay() {
        let session = OverlayScreenSession(resolver: makeResolver(indexToResolve: 1))

        XCTAssertEqual(session.visibleFrame(), secondaryVisibleFrame)
    }

    /// Re-resolving mid-session would let the overlay hop displays in the
    /// middle of a sentence just because the pointer wandered.
    func testKeepsTheFirstDisplayEvenWhenTheResolverWouldNowChooseAnother() {
        let resolver = makeResolver(indexToResolve: 1)
        let session = OverlayScreenSession(resolver: resolver)

        XCTAssertEqual(session.visibleFrame(), secondaryVisibleFrame)
        resolver.indexToResolve = 0

        XCTAssertEqual(session.visibleFrame(), secondaryVisibleFrame)
        XCTAssertEqual(resolver.resolveCount, 1)
    }

    // MARK: - A new session picks again

    func testEndingTheSessionResolvesTheDisplayAgain() {
        let resolver = makeResolver(indexToResolve: 1)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertEqual(session.visibleFrame(), secondaryVisibleFrame)

        session.end()
        resolver.indexToResolve = 0

        XCTAssertEqual(session.visibleFrame(), primaryVisibleFrame)
        XCTAssertEqual(resolver.resolveCount, 2)
    }

    // MARK: - Displays changing underneath a live session

    /// Reusing a display index means it can go stale. Unplugging the chosen
    /// monitor mid-dictation must not leave the overlay stranded off-screen.
    func testResolvesAgainWhenTheChosenDisplayIsUnplugged() {
        let resolver = makeResolver(indexToResolve: 1)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertEqual(session.visibleFrame(), secondaryVisibleFrame)

        resolver.frames = [primaryVisibleFrame]
        resolver.indexToResolve = 0

        XCTAssertEqual(session.visibleFrame(), primaryVisibleFrame)
        XCTAssertEqual(resolver.resolveCount, 2)
    }

    /// Display geometry is cheap to read and does change while the overlay is
    /// up — the dock hides, the menu bar reveals — so it is re-read per update
    /// even though the display choice is not.
    func testRereadsDisplayGeometryOnEveryUpdate() {
        let resolver = makeResolver()
        let session = OverlayScreenSession(resolver: resolver)

        _ = session.visibleFrame()
        _ = session.visibleFrame()
        _ = session.visibleFrame()

        XCTAssertEqual(resolver.visibleFramesCount, 3)
    }

    // MARK: - Nothing to place the overlay on

    func testReturnsNilWhenThereAreNoDisplays() {
        let resolver = SpyResolver(frames: [], indexToResolve: 0)
        let session = OverlayScreenSession(resolver: resolver)

        XCTAssertNil(session.visibleFrame())
    }

    func testReturnsNilWhenNoDisplayCanBeChosen() {
        let session = OverlayScreenSession(resolver: makeResolver(indexToResolve: nil))

        XCTAssertNil(session.visibleFrame())
    }

    /// A failed choice must not be cached as if it were a decision, or the
    /// overlay would stay unplaced for the rest of the session.
    func testRetriesAfterAFailedChoice() {
        let resolver = makeResolver(indexToResolve: nil)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertNil(session.visibleFrame())

        resolver.indexToResolve = 1

        XCTAssertEqual(session.visibleFrame(), secondaryVisibleFrame)
    }

    func testReturnsNilWhenTheChosenIndexIsOutOfRange() {
        let session = OverlayScreenSession(resolver: makeResolver(indexToResolve: 5))

        XCTAssertNil(session.visibleFrame())
    }
}
