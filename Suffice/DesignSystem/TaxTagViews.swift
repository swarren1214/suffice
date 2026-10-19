import SwiftUI

/// A tax tag's icon in its pale circle.
struct TaxTagIcon: View {
    var tag: TaxTag
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Image(systemName: tag.symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(isDark ? tag.color.color : tag.color.ink)
            .frame(width: size, height: size)
            .background(isDark ? tag.color.color.opacity(0.22) : tag.color.tint, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A tax tag's name in its colors: "Medical" in green, "Charitable" in yellow. "None" in gray.
struct TaxTagPill: View {
    var tag: TaxTag
    var short = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Text(short ? tag.shortName : tag.name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isDark ? tag.color.color : tag.color.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isDark ? tag.color.color.opacity(0.22) : tag.color.tint, in: .capsule)
            .lineLimit(1)
    }
}
