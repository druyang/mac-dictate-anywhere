//
//  OverlayScreenSession.swift
//  Dictate Anywhere
//
//  Holds the dictation overlay's chosen display for one visible session.
//

import CoreGraphics

/// Remembers which display the overlay picked, for as long as it stays up.
///
/// Choosing a display is expensive — it crosses a process boundary to ask the
/// focused application where it is — and `OverlayWindow` repositions itself on
/// every update, which for the listening waveform is about thirty times a
/// second. Choosing per update would put those synchronous calls on the main
/// thread at that rate, stalling the UI whenever the target app is slow to
/// answer, and would also let the overlay hop displays mid-sentence if the
/// pointer wandered. So the display is chosen on the first update of a session
/// and kept until the overlay hides.
final class OverlayScreenSession {
    private let resolver: OverlayScreenResolving
    private var chosenIndex: Int?

    init(resolver: OverlayScreenResolving = SystemOverlayScreenResolver()) {
        self.resolver = resolver
    }

    /// Visible frame of this session's display, choosing one on first use.
    ///
    /// Display geometry itself is cheap and does shift while the overlay is up
    /// — the dock hides, the menu bar reveals — so it is re-read every time
    /// even though the choice of display is not.
    func visibleFrame() -> CGRect? {
        let frames = resolver.visibleFrames()

        // Reusing an index means it can go stale: a display unplugged
        // mid-dictation would otherwise strand the overlay off-screen.
        if let chosenIndex, chosenIndex < frames.count {
            return frames[chosenIndex]
        }

        // Left uncached when nothing can be chosen, so a lookup that failed
        // once does not leave the overlay unplaced for the whole session.
        guard let index = resolver.resolveScreenIndex(), index < frames.count else { return nil }

        chosenIndex = index
        return frames[index]
    }

    /// Ends the session, so the next appearance chooses its display afresh.
    func end() {
        chosenIndex = nil
    }
}
