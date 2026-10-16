import SwiftUI
import UIKit

/// A color as plain numbers, for the card color math: shading in HSL and WCAG contrast.
nonisolated struct RGB: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    static let white = RGB(hex: 0xFFFFFF)
    static let ink = RGB(hex: 0x111111)

    var color: Color { Color(red: r, green: g, blue: b) }

    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Lighter or darker by `lightness` points (of 100), and turned by `hue` degrees.
    func shifted(lightness: Double, hue: Double = 0) -> RGB {
        let current = hsl
        var h = (current.h + hue).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let l = min(max(current.l + lightness / 100, 0.04), 0.96)
        return RGB(hue: h, saturation: current.s, lightness: l)
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        guard high != low else { return (0, 0, l) }
        let d = high - low
        let s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
        var h: Double
        switch high {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    init(hue h: Double, saturation s: Double, lightness l: Double) {
        let a = s * min(l, 1 - l)
        func f(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            return l - a * max(-1, min(k - 3, min(9 - k, 1)))
        }
        self.init(r: f(0), g: f(8), b: f(4))
    }
}

/// Where a card's color comes from: the bank's logo (when it has one), or one of the
/// fallback styles. Someone can pick a style for any card in its Card color row.
nonisolated enum CardStyle: String, CaseIterable, Identifiable, Sendable {
    case automatic, graphite, dusk, sage, sand

    var id: String { rawValue }

    var name: String {
        self == .automatic ? "Automatic" : rawValue.capitalized
    }

    /// The fallback styles, used when there's no logo color.
    static let fallbacks: [CardStyle] = [.graphite, .dusk, .sage, .sand]

    var base: RGB? {
        switch self {
        case .automatic: nil
        case .graphite: RGB(hex: 0x3A3D45)
        case .dusk: RGB(hex: 0x4A4E8F)
        case .sage: RGB(hex: 0x5E8C6A)
        case .sand: RGB(hex: 0xE2D3B0)
        }
    }

    /// The fallback an account gets when it has no logo: the same one every time.
    static func fallback(for id: UUID) -> CardStyle {
        let hash = id.uuidString.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return fallbacks[Int(hash % UInt32(fallbacks.count))]
    }
}

/// A card's colors: a three-stop gradient from one base color, and black or white text,
/// whichever reads better against both ends of it.
nonisolated struct CardPalette: Hashable, Sendable {
    var start: RGB
    var base: RGB
    var end: RGB
    var ink: RGB

    init(base: RGB, angle: (start: Double, end: Double) = (-10, 9)) {
        self.base = base
        start = base.shifted(lightness: angle.start, hue: -6)
        end = base.shifted(lightness: angle.end, hue: 10)
        let stops = [start, base, end]
        let onWhite = stops.map { RGB.white.contrast(with: $0) }.min() ?? 0
        let onInk = stops.map { RGB.ink.contrast(with: $0) }.min() ?? 0
        ink = onWhite >= onInk ? .white : .ink
    }

    var isDarkText: Bool { ink == .ink }

    var face: LinearGradient {
        LinearGradient(
            stops: [.init(color: start.color, location: 0), .init(color: base.color, location: 0.55), .init(color: end.color, location: 1)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// All accounts: the light green of the old Total cash card.
    static let total = CardPalette(base: RGB(hex: 0xA8E3B6), angle: (6, 10))
}

/// The colors pulled from bank logos, so each logo is looked at once.
@MainActor
enum LogoColors {
    private static var cache: [URL: RGB?] = [:]

    /// The main color of `image`, the logo at `url`, or nil when it's black, white or gray (a
    /// fallback style suits those better). Worked out once per logo.
    static func color(for url: URL, image: UIImage) async -> RGB? {
        if let known = cache[url] { return known }
        let color = await Task.detached(priority: .utility) { LogoColors.dominant(in: image) }.value
        cache[url] = color
        return color
    }

    /// The most common colorful hue in the image, averaged. Near-white, near-black and gray
    /// pixels don't count; nor does a hue that's only a sliver of the logo.
    nonisolated static func dominant(in image: UIImage) -> RGB? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var buckets: [Int: (weight: Double, r: Double, g: Double, b: Double)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let color = RGB(r: Double(pixels[index]) / 255 / alpha, g: Double(pixels[index + 1]) / 255 / alpha, b: Double(pixels[index + 2]) / 255 / alpha)
            let high = max(color.r, color.g, color.b), low = min(color.r, color.g, color.b)
            let chroma = high - low
            guard chroma > 0.22, high > 0.18, low < 0.92 else { continue }
            // Centered on red, so reds either side of 0° land together.
            let bucket = Int((color.hsl.h + 15) / 30) % 12
            var entry = buckets[bucket] ?? (0, 0, 0, 0)
            entry.weight += chroma
            entry.r += color.r * chroma
            entry.g += color.g * chroma
            entry.b += color.b * chroma
            buckets[bucket] = entry
        }
        guard let best = buckets.values.max(by: { $0.weight < $1.weight }),
              best.weight > Double(side * side) * 0.04 else { return nil }
        return RGB(r: best.r / best.weight, g: best.g / best.weight, b: best.b / best.weight)
    }
}
