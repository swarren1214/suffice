import SwiftUI
import UIKit

/// A merchant's logo, fitted to the round avatar.
///
/// Logos arrive in all shapes: full-bleed squares (Uber), circles or rounded tiles floating on
/// white or transparent padding (McDonald's, Starbucks), or bare wordmarks. Shown as-is in a
/// circle, the padded ones look shrunken inside a white ring. So each logo is looked at once
/// when it loads: padding is trimmed, tiles and round badges fill the circle, and wordmarks
/// get even breathing room on their own background color.
struct MerchantLogoImage: View {
    var url: URL
    var size: CGFloat
    @State private var image: UIImage?

    init(url: URL, size: CGFloat) {
        self.url = url
        self.size = size
        _image = State(initialValue: LogoStore.shared.cached(url))
    }

    var body: some View {
        // A clear placeholder holds the space until the logo loads: on an empty view SwiftUI
        // never runs `.task`, so the download would never start.
        ZStack {
            Color.clear
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .background(Color.white)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .task(id: url) {
            guard image == nil else { return }
            let loaded = await LogoStore.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// Downloads and fits logos once per launch; repeat merchants come from memory.
@MainActor
final class LogoStore {
    static let shared = LogoStore()

    private let cache = NSCache<NSURL, UIImage>()
    private var loading: [URL: Task<UIImage?, Never>] = [:]

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if let running = loading[url] { return await running.value }
        let task = Task<UIImage?, Never> {
            // Logo.dev answers 404 for merchants it doesn't know: the initial stays.
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return await Task.detached(priority: .utility) { LogoFitting.fitted(data) }.value
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// The image work behind `MerchantLogoImage`, off the main thread.
nonisolated enum LogoFitting {
    /// How a logo should sit in the circle.
    nonisolated enum Shape: Equatable {
        /// Already edge to edge: use it as is.
        case fullBleed
        /// A tile or round badge on padding: crop the padding so it fills the circle.
        case tile
        /// A wordmark or loose shape: trim, then center it with room around it.
        case mark
    }

    private static let sampleSide = 96

    static func fitted(_ data: Data) -> UIImage? {
        guard let source = UIImage(data: data), let cgImage = source.cgImage else { return nil }
        guard let pixels = Pixels(cgImage, side: sampleSide) else { return source }
        guard let background = pixels.background else { return source }
        guard let box = pixels.contentBox(background: background) else { return nil }

        switch shape(of: pixels, box: box, background: background) {
        case .fullBleed:
            return source
        case .tile:
            return crop(cgImage, to: box, sampledAt: pixels.size)
        case .mark:
            guard let trimmed = crop(cgImage, to: box, sampledAt: pixels.size) else { return source }
            return padded(trimmed, on: background.color)
        }
    }

    static func shape(of pixels: Pixels, box: CGRect, background: Pixels.Background) -> Shape {
        let side = CGFloat(pixels.size)
        if box.width >= side * 0.94 && box.height >= side * 0.94 { return .fullBleed }
        // Walk a ring just inside the trimmed logo: a tile or badge is solid there, a wordmark
        // mostly isn't.
        var solid = 0
        let samples = 72
        for step in 0..<samples {
            let angle = Double(step) / Double(samples) * 2 * .pi
            let x = box.midX + CGFloat(cos(angle)) * box.width * 0.42
            let y = box.midY + CGFloat(sin(angle)) * box.height * 0.42
            if !pixels.isBackground(x: Int(x), y: Int(y), background) { solid += 1 }
        }
        let squareish = abs(box.width - box.height) <= max(box.width, box.height) * 0.12
        return squareish && Double(solid) / Double(samples) >= 0.85 ? .tile : .mark
    }

    private static func crop(_ image: CGImage, to box: CGRect, sampledAt side: Int) -> UIImage? {
        let scaleX = CGFloat(image.width) / CGFloat(side)
        let scaleY = CGFloat(image.height) / CGFloat(side)
        let rect = CGRect(x: box.minX * scaleX, y: box.minY * scaleY, width: box.width * scaleX, height: box.height * scaleY).integral
        return image.cropping(to: rect).map { UIImage(cgImage: $0) }
    }

    /// The trimmed mark centered on a square of its own background, about 70% across.
    private static func padded(_ mark: UIImage, on color: UIColor) -> UIImage {
        let longest = max(mark.size.width, mark.size.height)
        let canvas = longest / 0.7
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
            mark.draw(in: CGRect(
                x: (canvas - mark.size.width) / 2,
                y: (canvas - mark.size.height) / 2,
                width: mark.size.width,
                height: mark.size.height
            ))
        }
    }

    /// A small RGBA copy of the logo to measure.
    nonisolated struct Pixels {
        let size: Int
        private let bytes: [UInt8]

        nonisolated struct Background {
            var red: Double, green: Double, blue: Double
            var isClear: Bool

            /// What fills around a wordmark: its own background, or white for transparent ones.
            var color: UIColor {
                isClear ? .white : UIColor(red: red, green: green, blue: blue, alpha: 1)
            }
        }

        init?(_ image: CGImage, side: Int) {
            var buffer = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                // Flip so row 0 is the top, matching CGImage.cropping coordinates.
                context.translateBy(x: 0, y: CGFloat(side))
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { return nil }
            size = side
            bytes = buffer
        }

        /// (red, green, blue, alpha), 0...1, colors un-premultiplied.
        func rgba(x: Int, y: Int) -> (Double, Double, Double, Double) {
            let x = min(max(x, 0), size - 1), y = min(max(y, 0), size - 1)
            let index = (y * size + x) * 4
            let alpha = Double(bytes[index + 3]) / 255
            guard alpha > 0 else { return (0, 0, 0, 0) }
            return (Double(bytes[index]) / 255 / alpha, Double(bytes[index + 1]) / 255 / alpha, Double(bytes[index + 2]) / 255 / alpha, alpha)
        }

        /// The padding color, read from the corners. Nil when they disagree, which means the
        /// logo runs to the edges.
        var background: Background? {
            let corners = [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)].map { rgba(x: $0.0, y: $0.1) }
            if corners.allSatisfy({ $0.3 < 0.1 }) {
                return Background(red: 1, green: 1, blue: 1, isClear: true)
            }
            guard corners.allSatisfy({ $0.3 > 0.9 }) else { return nil }
            let first = corners[0]
            for corner in corners.dropFirst() where distance(corner, first) > 0.08 { return nil }
            return Background(red: first.0, green: first.1, blue: first.2, isClear: false)
        }

        func isBackground(x: Int, y: Int, _ background: Background) -> Bool {
            let pixel = rgba(x: x, y: y)
            if pixel.3 < 0.1 { return true }
            if background.isClear { return false }
            return pixel.3 > 0.9 && distance(pixel, (background.red, background.green, background.blue, 1)) <= 0.08
        }

        /// The smallest box around everything that isn't padding, in sample pixels.
        func contentBox(background: Background) -> CGRect? {
            var minX = size, minY = size, maxX = -1, maxY = -1
            for y in 0..<size {
                for x in 0..<size where !isBackground(x: x, y: y, background) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        private func distance(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double)) -> Double {
            max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
        }
    }
}
