import HearthData
import HearthModel
import SwiftUI

/// Cover / avatar of any item. Square with rounded corners for media, circle for people.
///
/// Loads through `HearthData.shared.images`, decodes off the main actor and caches decoded images
/// in memory. Non-square covers are letterboxed on top of a blurred copy.
public struct ItemImage: View {
    let id: ItemIdentifier?
    let size: ImageSize
    let cornerRadius: CGFloat
    let showsStatus: Bool
    let placeholderSymbol: String?

    @State private var image: DecodedImage?
    /// The item `image` belongs to – the view may be reused for another item (lists, the mini player).
    @State private var imageID: ItemIdentifier?

    /// - Parameters:
    ///   - id: The item; `nil` shows the placeholder.
    ///   - size: Requested image size (bumped one step when "High quality images" is on).
    ///   - cornerRadius: Corner radius for non-person items.
    ///   - showsStatus: Adds the cover status overlay (progress / download corner).
    public init(id: ItemIdentifier?, size: ImageSize = .small, cornerRadius: CGFloat = 8, showsStatus: Bool = false, placeholderSymbol: String? = nil) {
        self.id = id
        self.size = size
        self.cornerRadius = cornerRadius
        self.showsStatus = showsStatus
        self.placeholderSymbol = placeholderSymbol
        if let id, let cached = DecodedImageCache.shared.image(for: DecodedImageCache.key(for: id, size: size)) {
            _image = State(initialValue: cached)
            _imageID = State(initialValue: id)
        }
    }

    private var isPerson: Bool {
        id?.kind == .author || id?.kind == .narrator
    }

    private var shape: AnyShape {
        isPerson ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var effectiveSize: ImageSize {
        guard AppSettings.shared.highQualityImages else { return size }
        return ImageSize.allCases.first { $0 > size } ?? size
    }

    public var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                // Never show another item's cover while this one loads.
                if let image, imageID == id {
                    imageContent(image)
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsStatus, let id, !isPerson {
                    CoverStatusOverlay(id: id)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.stroke(.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(shape)
            .accessibilityHidden(true)
            .task(id: TaskKey(id: id, size: effectiveSize)) {
                await load()
            }
    }

    @ViewBuilder
    private func imageContent(_ image: DecodedImage) -> some View {
        let picture = Image(decorative: image.cgImage, scale: 1)
        if image.isRoughlySquare || isPerson {
            picture
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                picture
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 18)
                    .opacity(0.8)
                picture
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
    }

    private var placeholder: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: placeholderSymbol ?? id?.kind.systemImage ?? "photo")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                    .foregroundStyle(.secondary)
                    .frame(width: proxy.size.width * 0.36, height: proxy.size.height * 0.36)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func load() async {
        guard let id, id.kind != .narrator else {
            image = nil
            imageID = nil
            return
        }
        let key = DecodedImageCache.key(for: id, size: effectiveSize)
        if let cached = DecodedImageCache.shared.image(for: key) {
            image = cached
            imageID = id
            return
        }
        // Another item's (or no) image: show a cached variant of this item while the requested size loads,
        // else the placeholder. The same item's current image stays when only the size changes.
        if image == nil || imageID != id {
            image = ImageSize.allCases.reversed().lazy.compactMap({ DecodedImageCache.shared.image(for: DecodedImageCache.key(for: id, size: $0)) }).first
            imageID = image == nil ? nil : id
        }
        let loaded = await ImageDecoder.load(id, size: effectiveSize)
        guard !Task.isCancelled else { return }
        if let loaded {
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                imageID = id
            }
        }
    }

    private struct TaskKey: Hashable {
        var id: ItemIdentifier?
        var size: ImageSize
    }
}

/// A cover with a soft shadow and the status overlay – used in grids and headers.
public struct ItemCover: View {
    let id: ItemIdentifier?
    let size: ImageSize
    let cornerRadius: CGFloat
    let showsStatus: Bool

    public init(id: ItemIdentifier?, size: ImageSize = .regular, cornerRadius: CGFloat = 10, showsStatus: Bool = true) {
        self.id = id
        self.size = size
        self.cornerRadius = cornerRadius
        self.showsStatus = showsStatus
    }

    public var body: some View {
        ItemImage(id: id, size: size, cornerRadius: cornerRadius, showsStatus: showsStatus)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }
}

#if DEBUG
#Preview("Item images") {
    HStack {
        ItemImage(id: PreviewFixtures.audiobook.id, showsStatus: true)
        ItemImage(id: PreviewFixtures.author.id)
        ItemImage(id: PreviewFixtures.podcast.id)
    }
    .frame(height: 100)
    .padding()
}
#endif
