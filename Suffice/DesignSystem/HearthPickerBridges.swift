import SwiftUI

// Bridges between Suffice's stored colors and the shared Hearth Icon & Color picker
// (Services/Hearth/HearthPicker.swift). Nothing about how colors are saved changes: a
// category's or bill's color is still a CategoryColor ("orange" or "#RRGGBB"), and an
// account's is still its colorHex.

extension CategoryColor {
    /// The color as the Hearth picker sees it. Custom colors come across exactly (a palette
    /// color when they match one, otherwise Custom); the old named presets ("orange", "blue"…)
    /// land on the nearest palette color, so they don't show up as Custom.
    nonisolated var hearthChoice: HearthColorChoice {
        get {
            isCustom ? HearthColorChoice(hex: hexValue) : .palette(HearthPalette.nearest(to: hexValue).id)
        }
        set {
            // Re-setting what's already shown (Cancel in the picker) leaves a preset as it was.
            guard newValue != hearthChoice else { return }
            self = CategoryColor(newValue)
        }
    }

    /// A color picked in the Hearth picker, saved as "#RRGGBB".
    nonisolated init(_ choice: HearthColorChoice) {
        self.init(hex: choice.hex)
    }
}

extension Binding where Value == Int {
    /// An account's colorHex (0xRRGGBB) as a Hearth picker color. Account colors are bank colors,
    /// so they come across exactly: a palette color when they match one, otherwise Custom.
    var hearthAccountColor: Binding<HearthColorChoice> {
        let base = self
        return Binding<HearthColorChoice>(
            get: { HearthColorChoice(hex: UInt32(truncatingIfNeeded: base.wrappedValue) & 0xFFFFFF) },
            set: { choice in
                let hex = Int(choice.hex)
                if hex != base.wrappedValue { base.wrappedValue = hex }
            }
        )
    }
}

/// The "Color" row for things that only have a color (bills, accounts): a swatch, the word
/// Color, and the color's name. Opens the color-only Hearth picker.
struct HearthColorSwatchLabel: View {
    let color: HearthColorChoice
    var title: String = "Color"

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color.color)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(color.name)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the color picker")
    }
}
