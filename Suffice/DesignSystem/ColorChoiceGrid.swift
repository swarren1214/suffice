import SwiftUI
import UIKit

/// The color choices for a budget or a bill: the nine presets, then the system color picker for
/// any other color. Five across, so it fits an iPhone without squeezing.
struct ColorChoiceGrid: View {
    @Binding var selection: CategoryColor

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(CategoryColor.allCases) { option in
                Button {
                    withAnimation(.snappy) { selection = option }
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 28, height: 28)
                        .overlay(selectionRing(option == selection, color: option.color))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }

            // The system picker: grid, spectrum, sliders and the eyedropper. It starts from the
            // current color, so a preset can be nudged into a custom one.
            ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .overlay(selectionRing(selection.isCustom, color: selection.color).allowsHitTesting(false))
                .frame(width: 44, height: 44)
                .accessibilityLabel("Custom color")
                .accessibilityAddTraits(selection.isCustom ? .isSelected : [])
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { selection.color },
            set: { newValue in
                if let hex = newValue.hexValue {
                    selection = CategoryColor(hex: hex)
                }
            }
        )
    }

    private func selectionRing(_ isSelected: Bool, color: Color) -> some View {
        Circle()
            .strokeBorder(isSelected ? color : .clear, lineWidth: 2.5)
            .frame(width: 38, height: 38)
    }
}

extension Color {
    /// The color as 0xRRGGBB in sRGB, or nil if it can't be read.
    var hexValue: UInt32? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return (byte(red) << 16) | (byte(green) << 8) | byte(blue)
    }
}
