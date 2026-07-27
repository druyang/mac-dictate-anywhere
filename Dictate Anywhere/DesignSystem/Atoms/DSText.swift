import SwiftUI

/// Atom: section overline ("STARTUP", "AUDIO", …).
struct DSOverline: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.Fonts.ui(12, .semibold))
            .tracking(0.4)
            .foregroundStyle(DS.Colors.textSecondary)
    }
}

/// Atom: 1pt hairline divider used inside cards.
struct DSDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.borderSoft)
            .frame(height: 1)
    }
}

/// Atom: inline hint line with a lightbulb icon. Quiet help, so it takes the
/// neutral tone — an accent glyph here reads as "pay attention" it hasn't earned.
struct DSHint: View {
    let text: String
    var icon: String = "lightbulb"
    var tone: DS.Tone = .neutral

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tone.icon)
            Text(text)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Atom: message panel with tinted background (design "Panel").
///
/// The `tone` carries the meaning — a warning, an error and a plain note each
/// get their own hue, icon and border so they can't be mistaken for one another.
struct DSPanel: View {
    let text: String
    var tone: DS.Tone = .info
    /// Overrides the tone's default icon when a more specific glyph fits.
    var icon: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon ?? tone.defaultIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tone.icon)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(DS.Fonts.ui(12.5))
                .lineSpacing(12.5 * 0.55 - 3)
                .foregroundStyle(tone.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(tone.fill, in: RoundedRectangle(cornerRadius: DS.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(tone.border, lineWidth: 1)
        )
    }
}
