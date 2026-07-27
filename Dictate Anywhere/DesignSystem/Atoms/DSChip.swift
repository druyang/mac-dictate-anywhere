import SwiftUI

/// Atom: small capsule chip ("um", "MIT License", model names, …).
/// Optionally removable (trailing ×) or tappable.
struct DSChip: View {
    let text: String
    var isSelected: Bool = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(DS.Fonts.ui(12, .medium))
                .foregroundStyle(isSelected ? Color.white : DS.Colors.ink)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(isSelected ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(DS.Colors.bgInset), in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : DS.Colors.border, lineWidth: 1))
    }
}

/// Atom: status pill with a colored dot ("Ready", "Not downloaded", …).
/// The `tone` supplies dot, text and fill; the individual colors stay
/// overridable for one-off cases.
struct DSStatusPill: View {
    let text: String
    var tone: DS.Tone = .success
    var dotColor: Color?
    var textColor: Color?
    var fill: Color?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor ?? tone.icon)
                .frame(width: 7, height: 7)
            Text(text)
                .font(DS.Fonts.ui(12.5, .semibold))
                .foregroundStyle(textColor ?? tone.text)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(fill ?? tone.fill, in: Capsule())
    }
}

/// Atom: keyboard keycap ("⌘", "L ⌃", …).
struct DSKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Fonts.ui(12.5, .semibold))
            .foregroundStyle(DS.Colors.ink)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(DS.Colors.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.Colors.border, lineWidth: 1))
            .shadow(color: DS.Colors.keycapShadow, radius: 0, x: 0, y: 1.5)
    }
}
