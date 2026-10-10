import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Platform independent image helpers (ImageIO + CoreGraphics; no UIKit/AppKit).
enum ImageProcessing {
    /// Decodes a downsampled image whose longest side is at most `maxPixelSize`.
    static func thumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG thumbnail data (used for widget snapshots).
    static func jpegThumbnail(from data: Data, maxPixelSize: Int, quality: Double = 0.8) -> Data? {
        guard let image = thumbnail(from: data, maxPixelSize: maxPixelSize) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// RGBA8 pixels of an image scaled to fit `maxSide`.
    static func rgbaPixels(of image: CGImage, maxSide: Int = 48) -> (pixels: [UInt8], count: Int)? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width * height) : nil
    }
}

/// Saturation-weighted dominant color: pixels are bucketed by hue, weighted by saturation and brightness; the
/// strongest hue band (with its neighbours) wins. Mostly grey images fall back to their average color.
enum DominantColor {
    static let hueBuckets = 36

    static func compute(from data: Data) -> RGBColor? {
        guard let image = ImageProcessing.thumbnail(from: data, maxPixelSize: 64) else { return nil }
        return compute(from: image)
    }

    static func compute(from image: CGImage) -> RGBColor? {
        guard let (pixels, count) = ImageProcessing.rgbaPixels(of: image) else { return nil }
        return compute(rgba: pixels, count: count)
    }

    /// `rgba`: premultiplied RGBA8 pixels.
    static func compute(rgba: [UInt8], count: Int) -> RGBColor? {
        guard count > 0, rgba.count >= count * 4 else { return nil }
        var weights = [Double](repeating: 0, count: hueBuckets)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: hueBuckets)
        var grey = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
        var opaque = 0.0

        for index in 0..<count {
            let alpha = Double(rgba[index * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(rgba[index * 4]) / 255 / alpha
            let g = Double(rgba[index * 4 + 1]) / 255 / alpha
            let b = Double(rgba[index * 4 + 2]) / 255 / alpha
            opaque += 1

            let maxValue = max(r, g, b)
            let minValue = min(r, g, b)
            let delta = maxValue - minValue
            let saturation = maxValue > 0 ? delta / maxValue : 0
            let brightness = maxValue

            grey.r += r
            grey.g += g
            grey.b += b
            grey.n += 1

            guard saturation > 0.2, brightness > 0.15 else { continue }
            var hue: Double
            if maxValue == r {
                hue = (g - b) / delta
            } else if maxValue == g {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue = (hue * 60).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            let bucket = min(hueBuckets - 1, Int(hue / 360 * Double(hueBuckets)))
            // Favour vivid, mid-to-bright pixels; very dark ones contribute little.
            let weight = saturation * saturation * (0.3 + 0.7 * brightness)
            weights[bucket] += weight
            sums[bucket].r += r * weight
            sums[bucket].g += g * weight
            sums[bucket].b += b * weight
        }

        guard grey.n > 0 else { return nil }
        let chromaticWeight = weights.reduce(0, +)

        // Not enough color: average color.
        guard chromaticWeight > opaque * 0.02 else {
            return RGBColor(red: grey.r / grey.n, green: grey.g / grey.n, blue: grey.b / grey.n)
        }

        var best = 0
        var bestScore = -1.0
        for bucket in 0..<hueBuckets {
            let score = weights[bucket] + 0.5 * weights[(bucket + hueBuckets - 1) % hueBuckets] + 0.5 * weights[(bucket + 1) % hueBuckets]
            if score > bestScore {
                bestScore = score
                best = bucket
            }
        }
        var total = 0.0
        var color = (r: 0.0, g: 0.0, b: 0.0)
        for offset in -1...1 {
            let bucket = (best + offset + hueBuckets) % hueBuckets
            let factor = offset == 0 ? 1 : 0.5
            total += weights[bucket] * factor
            color.r += sums[bucket].r * factor
            color.g += sums[bucket].g * factor
            color.b += sums[bucket].b * factor
        }
        guard total > 0 else { return nil }
        return RGBColor(red: min(1, color.r / total), green: min(1, color.g / total), blue: min(1, color.b / total))
    }
}
