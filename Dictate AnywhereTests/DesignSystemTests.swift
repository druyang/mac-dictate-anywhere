import XCTest
import SwiftUI
@testable import Dictate_Anywhere_Dev

final class DesignSystemTests: XCTestCase {

    // MARK: - Color(hex:)

    private func components(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }

    func testColorHexDecodesChannels() {
        let c = components(Color(hex: 0xDE6A3B))
        XCTAssertEqual(c.r, Double(0xDE) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0x6A) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0x3B) / 255, accuracy: 0.001)
        XCTAssertEqual(c.a, 1, accuracy: 0.001)
    }

    func testColorHexOpacity() {
        let c = components(Color(hex: 0x000000, opacity: 0.5))
        XCTAssertEqual(c.a, 0.5, accuracy: 0.001)
    }

    func testColorHexBlackAndWhite() {
        let black = components(Color(hex: 0x000000))
        XCTAssertEqual(black.r + black.g + black.b, 0, accuracy: 0.001)
        let white = components(Color(hex: 0xFFFFFF))
        XCTAssertEqual(white.r + white.g + white.b, 3, accuracy: 0.001)
    }

    // MARK: - Token values match design.pen variables

    func testAccentToken() {
        let c = components(DS.Colors.accent)
        XCTAssertEqual(c.r, Double(0xDE) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0x6A) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0x3B) / 255, accuracy: 0.001)
    }

    func testAccentFollowsAssetCatalog() {
        // DS.Colors.accent must be the catalog color, not a hardcoded hex.
        let catalog = NSColor(named: "AccentColor")?.usingColorSpace(.sRGB)
        XCTAssertNotNil(catalog)
        let c = components(DS.Colors.accent)
        XCTAssertEqual(c.r, catalog!.redComponent, accuracy: 0.001)
        XCTAssertEqual(c.g, catalog!.greenComponent, accuracy: 0.001)
        XCTAssertEqual(c.b, catalog!.blueComponent, accuracy: 0.001)
    }

    /// The derived variants must reproduce the design.pen palette (within a
    /// small tolerance) while the catalog accent is the default #DE6A3B.
    func testDerivedAccentVariantsMatchDesign() {
        let deep = components(DS.Colors.accentDeep)
        XCTAssertEqual(deep.r, Double(0xC4) / 255, accuracy: 0.04)
        XCTAssertEqual(deep.g, Double(0x55) / 255, accuracy: 0.04)
        XCTAssertEqual(deep.b, Double(0x2A) / 255, accuracy: 0.04)

        let soft = components(DS.Colors.accentSoft)
        XCTAssertEqual(soft.r, Double(0xF8) / 255, accuracy: 0.04)
        XCTAssertEqual(soft.g, Double(0xE5) / 255, accuracy: 0.04)
        XCTAssertEqual(soft.b, Double(0xD5) / 255, accuracy: 0.04)

        let panel = components(DS.Colors.panelText)
        XCTAssertEqual(panel.r, Double(0x8A) / 255, accuracy: 0.04)
        XCTAssertEqual(panel.g, Double(0x4A) / 255, accuracy: 0.04)
        XCTAssertEqual(panel.b, Double(0x28) / 255, accuracy: 0.04)
    }

    func testWindowBackgroundToken() {
        let c = components(DS.Colors.bgWindow)
        XCTAssertEqual(c.r, Double(0xFA) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0xF5) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0xEC) / 255, accuracy: 0.001)
    }

    func testSidebarBackgroundToken() {
        let c = components(DS.Colors.bgSidebar)
        XCTAssertEqual(c.r, Double(0xF3) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0xEC) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0xDF) / 255, accuracy: 0.001)
    }

    func testInkToken() {
        let c = components(DS.Colors.ink)
        XCTAssertEqual(c.r, Double(0x2B) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0x26) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0x20) / 255, accuracy: 0.001)
    }

    // MARK: - Semantic tones

    /// sRGB relative luminance per WCAG 2.1.
    private func luminance(_ color: Color) -> Double {
        let c = components(color)
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private func contrastRatio(_ a: Color, _ b: Color) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func isSameColor(_ a: Color, _ b: Color) -> Bool {
        let (x, y) = (components(a), components(b))
        return abs(x.r - y.r) < 0.004 && abs(x.g - y.g) < 0.004 && abs(x.b - y.b) < 0.004
    }

    /// A warning must never be paintable as an error (or as a brand tip):
    /// every tone owns a fill and an icon color no other tone uses.
    func testEveryToneIsVisuallyDistinct() {
        let tones = DS.Tone.allCases
        for (index, tone) in tones.enumerated() {
            for other in tones[(index + 1)...] {
                XCTAssertFalse(
                    isSameColor(tone.fill, other.fill),
                    "\(tone) and \(other) share the same panel fill"
                )
                XCTAssertFalse(
                    isSameColor(tone.icon, other.icon),
                    "\(tone) and \(other) share the same icon color"
                )
                XCTAssertFalse(
                    isSameColor(tone.text, other.text),
                    "\(tone) and \(other) share the same text color"
                )
            }
        }
    }

    /// The accent is the brand tint used by cards, chips, links and primary
    /// buttons. No tone may reuse it — that's what made every message, whatever
    /// its meaning, render as the same alarming card.
    func testNoToneReusesTheAccentPalette() {
        for tone in DS.Tone.allCases {
            XCTAssertFalse(isSameColor(tone.fill, DS.Colors.accentSoft), "\(tone) reuses accentSoft")
            XCTAssertFalse(isSameColor(tone.icon, DS.Colors.accent), "\(tone) reuses accent")
            XCTAssertFalse(isSameColor(tone.icon, DS.Colors.accentDeep), "\(tone) reuses accentDeep")
            XCTAssertFalse(isSameColor(tone.text, DS.Colors.panelText), "\(tone) reuses panelText")
        }
    }

    /// Body copy on a tinted panel must clear WCAG AA for normal text.
    func testToneTextMeetsContrastOnItsOwnFill() {
        for tone in DS.Tone.allCases {
            let ratio = contrastRatio(tone.text, tone.fill)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(tone) body text contrast is \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    /// The tone list is purely semantic: there is no brand tone to reach for,
    /// so a status surface has to pick a meaning from its context.
    func testToneVocabularyIsSemanticOnly() {
        XCTAssertEqual(DS.Tone.allCases, [.neutral, .info, .success, .warning, .danger])
    }

    /// Each tone needs a glyph of its own so the meaning survives at a glance
    /// (and for anyone who can't separate the hues).
    func testSeverityTonesCarryDistinctDefaultIcons() {
        XCTAssertEqual(DS.Tone.success.defaultIcon, "checkmark.circle")
        XCTAssertEqual(DS.Tone.warning.defaultIcon, "exclamationmark.triangle")
        XCTAssertEqual(DS.Tone.danger.defaultIcon, "xmark.circle")
        XCTAssertNotEqual(DS.Tone.warning.defaultIcon, DS.Tone.danger.defaultIcon)
    }

    func testFontFamiliesMatchDesign() {
        XCTAssertEqual(DS.Fonts.displayFamily, "Fraunces")
        XCTAssertEqual(DS.Fonts.uiFamily, "Inter")
    }

    func testBundledFontsAreRegistered() {
        // ATSApplicationFontsPath = "." must register both families in the host app.
        XCTAssertNotNil(NSFont(name: "Fraunces", size: 16), "Fraunces font not registered")
        XCTAssertNotNil(NSFont(name: "Inter", size: 13), "Inter font not registered")
    }

    func testMetricsMatchDesign() {
        XCTAssertEqual(DS.Metrics.sidebarWidth, 264)
        XCTAssertEqual(DS.Metrics.windowWidth, 1120)
        XCTAssertEqual(DS.Metrics.windowHeight, 780)
        XCTAssertEqual(DS.Radius.card, 12)
        XCTAssertEqual(DS.Radius.control, 9)
        XCTAssertEqual(DS.Spacing.section, 24)
        XCTAssertEqual(DS.Spacing.contentHorizontal, 44)
    }

    // MARK: - Waveform pill

    func testWaveformPillBarsMatchDesign() {
        let bars = DSWaveformPill.bars
        XCTAssertEqual(bars.count, 14)
        XCTAssertEqual(bars.filter(\.isActive).count, 6)
        // Design: bars 4–9 are the accent bars.
        for (index, bar) in bars.enumerated() {
            XCTAssertEqual(bar.isActive, (4...9).contains(index), "bar \(index)")
        }
        XCTAssertEqual(bars.map(\.height), [8, 14, 20, 12, 24, 17, 10, 22, 15, 26, 12, 18, 9, 14])
    }

    // MARK: - Dictation history filtering & date format

    private func entry(_ text: String) -> TranscriptHistoryEntry {
        TranscriptHistoryEntry(id: UUID(), text: text, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testDictationHistoryFilterEmptyQueryReturnsAll() {
        let entries = [entry("alpha"), entry("beta")]
        XCTAssertEqual(DictationHistoryView.filteredEntries(entries, searchText: "").count, 2)
        XCTAssertEqual(DictationHistoryView.filteredEntries(entries, searchText: "   ").count, 2)
    }

    func testDictationHistoryFilterIsCaseInsensitive() {
        let entries = [entry("Hello World"), entry("other")]
        let filtered = DictationHistoryView.filteredEntries(entries, searchText: "hello")
        XCTAssertEqual(filtered.map(\.text), ["Hello World"])
    }

    func testDictationHistoryFilterNoMatches() {
        let entries = [entry("alpha")]
        XCTAssertTrue(DictationHistoryView.filteredEntries(entries, searchText: "zzz").isEmpty)
    }

    func testDictationHistoryDateFormatMatchesDesign() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 15
        components.hour = 17; components.minute = 54
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!

        let formatter = DictationHistoryView.dateFormatter
        let original = formatter.locale
        formatter.locale = Locale(identifier: "en_US_POSIX")
        defer { formatter.locale = original }

        XCTAssertEqual(formatter.string(from: date), "Jul 15, 2026 · 5:54 PM")
    }

    // MARK: - Comparable.clamped

    func testClamped() {
        XCTAssertEqual(5.clamped(to: 0...10), 5)
        XCTAssertEqual((-1).clamped(to: 0...10), 0)
        XCTAssertEqual(11.clamped(to: 0...10), 10)
        XCTAssertEqual(0.75.clamped(to: 0.0...1.0), 0.75, accuracy: 0.0001)
    }
}
