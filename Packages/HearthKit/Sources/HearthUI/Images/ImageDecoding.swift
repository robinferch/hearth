import CoreGraphics
import Foundation
import HearthData
import HearthModel
import ImageIO

/// A decoded cover image. `CGImage` is immutable and safe to share across threads.
public struct DecodedImage: @unchecked Sendable, Equatable {
    public let cgImage: CGImage

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
    }

    public var aspectRatio: CGFloat {
        guard cgImage.height > 0 else { return 1 }
        return CGFloat(cgImage.width) / CGFloat(cgImage.height)
    }

    public var isRoughlySquare: Bool {
        (0.93...1.07).contains(aspectRatio)
    }
}

/// In-memory cache of decoded (thumbnail-sized) images, keyed by item + size.
public final class DecodedImageCache: @unchecked Sendable {
    public static let shared = DecodedImageCache()

    private final class Box: NSObject {
        let image: DecodedImage
        init(_ image: DecodedImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    init() {
        cache.countLimit = 500
        // Roughly 150 MB of decoded pixels.
        cache.totalCostLimit = 150 * 1024 * 1024
    }

    public static func key(for id: ItemIdentifier, size: ImageSize) -> String {
        "\(id.description)#\(size.rawValue)"
    }

    public func image(for key: String) -> DecodedImage? {
        cache.object(forKey: key as NSString)?.image
    }

    public func insert(_ image: DecodedImage, for key: String) {
        let cost = image.cgImage.bytesPerRow * image.cgImage.height
        cache.setObject(Box(image), forKey: key as NSString, cost: cost)
    }

    public func removeAll() {
        cache.removeAllObjects()
    }
}

/// Off-main image decoding with ImageIO (platform independent: iOS, watchOS, macOS).
public enum ImageDecoder {
    /// Decodes and downsamples `data` so that the longest side is at most `maxPixelSize`.
    public static func decode(_ data: Data, maxPixelSize: Int) -> DecodedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return DecodedImage(cgImage: image)
    }

    /// Loads an item's image through `ImageStore`, decoding off the main actor and caching the result.
    @MainActor
    public static func load(_ id: ItemIdentifier, size: ImageSize) async -> DecodedImage? {
        let key = DecodedImageCache.key(for: id, size: size)
        if let cached = DecodedImageCache.shared.image(for: key) {
            return cached
        }
        let store = HearthData.shared.images
        let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            guard let data = await store.imageData(for: id, size: size) else { return nil }
            return decode(data, maxPixelSize: size.width)
        }.value
        if let decoded {
            DecodedImageCache.shared.insert(decoded, for: key)
        }
        return decoded
    }
}
