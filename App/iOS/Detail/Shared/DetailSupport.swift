import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

// MARK: - Playback

/// Playback entry points of the detail screens (origin-aware, start at a time).
@MainActor
enum DetailPlayback {
    /// Plays `id` (from `time` if given) and opens the full player when a new item started.
    static func play(_ id: ItemIdentifier, origin: PlaybackOrigin = .none, at time: TimeInterval? = nil, alerts: AlertCenter, presentation: PlayerPresentation) async {
        let audio = AudioPlayer.shared
        let wasCurrent = audio.isCurrent(id)
        do {
            try await audio.play(id, origin: origin, at: time)
            if !wasCurrent {
                presentation.itemStarted()
            }
        } catch PlaybackError.downloadInProgress {
            // The shared flow offers "Cancel download & play".
            await AppItemActions.play(id, alerts: alerts, player: presentation)
        } catch {
            alerts.fail(error, title: String(localized: "Playback failed", table: "Detail"))
        }
    }

    static func playGrouping(_ id: ItemIdentifier, alerts: AlertCenter, presentation: PlayerPresentation) async {
        do {
            try await AudioPlayer.shared.play(grouping: id)
            presentation.itemStarted()
        } catch {
            alerts.fail(error, title: String(localized: "Playback failed", table: "Detail"))
        }
    }

    static func origin(for grouping: ItemIdentifier) -> PlaybackOrigin {
        switch grouping.kind {
        case .series: .series(grouping)
        case .podcast: .podcast(grouping)
        case .collection, .playlist: .collection(grouping)
        default: .none
        }
    }
}

extension ItemActionHandler {
    /// A copy whose `play` starts items with the given origin (Up Next from the series / podcast / collection).
    @MainActor
    func withPlaybackOrigin(_ origin: PlaybackOrigin, alerts: AlertCenter, presentation: PlayerPresentation) -> ItemActionHandler {
        var copy = self
        copy.play = { id in
            await DetailPlayback.play(id, origin: origin, alerts: alerts, presentation: presentation)
        }
        return copy
    }
}

/// Handles `hearth://seek/<seconds>` links in descriptions by starting `itemID` at that time.
struct SeekLinkHandler: ViewModifier {
    let itemID: ItemIdentifier?

    @Environment(AlertCenter.self) private var alerts
    @Environment(PlayerPresentation.self) private var presentation

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard let seconds = HTMLText.seekTime(from: url) else { return .systemAction }
            guard let itemID else { return .discarded }
            Task { await DetailPlayback.play(itemID, at: seconds, alerts: alerts, presentation: presentation) }
            return .handled
        })
    }
}

// MARK: - Loading

/// Loads a value, keeping the previous content visible while refreshing.
@MainActor
@Observable
final class DetailLoader<Value> {
    private(set) var state: LoadState<Value> = .loading
    private let load: @MainActor () async throws -> Value

    init(_ load: @escaping @MainActor () async throws -> Value) {
        self.load = load
    }

    var value: Value? { state.value }

    func reload() async {
        do {
            let value = try await load()
            state = .loaded(value)
        } catch is CancellationError {
            return
        } catch {
            if state.value == nil {
                state = .failed(error)
            }
        }
    }

    func update(_ transform: (inout Value) -> Void) {
        guard var value = state.value else { return }
        transform(&value)
        state = .loaded(value)
    }
}

// MARK: - Navigation title

extension View {
    /// Transparent navigation bar with the title fading in once the header (`threshold` points) scrolled away.
    /// Keeps `navigationTitle` set so the back button history menu shows the item name.
    func detailNavigationTitle(_ title: String, threshold: CGFloat = 240) -> some View {
        modifier(DetailTitleModifier(title: title, threshold: threshold))
    }
}

private struct DetailTitleModifier: ViewModifier {
    let title: String
    let threshold: CGFloat

    @State private var showsTitle = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > threshold
            } action: { _, newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsTitle = newValue
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(showsTitle ? 1 : 0)
                        .accessibilityHidden(!showsTitle)
                }
            }
    }
}

// MARK: - List helpers

extension View {
    /// A full-width list row without insets, separators or background (headers, shelves).
    func detailPlainRow(insets: EdgeInsets = EdgeInsets()) -> some View {
        listRowInsets(insets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Section header that toggles a collapsible section.
struct CollapsibleHeader: View {
    let title: String
    var detail: String?
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .textCase(nil)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isExpanded ? String(localized: "Expanded", table: "Detail") : String(localized: "Collapsed", table: "Detail"))
        .sensoryFeedback(.selection, trigger: isExpanded)
    }
}

/// Plain section title.
struct DetailSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Links

/// Navigation link for content embedded inside a list row (headers, grids, shelves). A `NavigationLink` there
/// would turn the whole row into a disclosure link; this pushes through the item action handler instead.
struct DetailLink<Label: View>: View {
    let destination: NavigationDestination
    @ViewBuilder let label: () -> Label

    @Environment(\.itemActionHandler) private var handler

    init(value destination: NavigationDestination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    var body: some View {
        Button {
            handler.navigate(destination)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Shelves

/// Horizontal shelf of audiobooks ("More in series X", "More by Y").
struct AudiobookShelf: View {
    let title: String
    let destination: NavigationDestination?
    let audiobooks: [Audiobook]

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let destination {
                    DetailLink(value: destination) {
                        HStack(spacing: 4) {
                            Text(title)
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                }
            }
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(audiobooks) { book in
                        DetailLink(value: .item(book.id)) {
                            AudiobookGridCell(audiobook: book)
                        }
                        .itemActions(for: .audiobook(book), swipeActions: false)
                        .frame(width: sizeClass == .compact ? 128 : 160)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Description

/// HTML description rendered as an attributed string with tappable links (and optionally timestamps).
/// Shows `collapsedLines` lines with a "More" button that expands inline or opens a sheet.
struct DescriptionView: View {
    enum Expansion {
        case inline
        case sheet(title: String)
    }

    let html: String?
    var collapsedLines = 6
    var linkTimestamps = false
    var expansion: Expansion = .inline
    var seekItemID: ItemIdentifier?

    @State private var text: AttributedString?
    @State private var isExpanded = false
    @State private var isSheetPresented = false

    private var isLong: Bool {
        guard let text else { return false }
        let characters = text.characters
        let newlines = characters.reduce(0) { $0 + ($1.isNewline ? 1 : 0) }
        return characters.count > collapsedLines * 55 || newlines >= collapsedLines
    }

    var body: some View {
        Group {
            if let text, !text.characters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .font(.callout)
                        .lineLimit(isExpanded ? nil : collapsedLines)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture {
                            if case .sheet = expansion, isLong {
                                isSheetPresented = true
                            }
                        }
                    if isLong {
                        Button {
                            switch expansion {
                            case .inline:
                                withAnimation(.snappy) { isExpanded.toggle() }
                            case .sheet:
                                isSheetPresented = true
                            }
                        } label: {
                            Text(isExpanded ? String(localized: "Less", table: "Detail") : String(localized: "More", table: "Detail"))
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
                .modifier(SeekLinkHandler(itemID: seekItemID))
            }
        }
        .task(id: html) {
            guard let html, !html.isEmpty else {
                text = nil
                return
            }
            let timestamps = linkTimestamps
            text = await Task.detached(priority: .userInitiated) {
                HTMLText.attributedString(from: html, linkTimestamps: timestamps)
            }.value
        }
        .sheet(isPresented: $isSheetPresented) {
            NavigationStack {
                ScrollView {
                    if let text {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .modifier(SeekLinkHandler(itemID: seekItemID))
                .navigationTitle(sheetTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .close) {
                            isSheetPresented = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var sheetTitle: String {
        if case .sheet(let title) = expansion { title } else { "" }
    }
}

// MARK: - Info rows

/// "Label  Value" row used in Details sections.
struct DetailInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(label)
        }
        .font(.subheadline)
    }
}

// MARK: - Background

/// Dominant-color hero gradient (header background) that extends under the navigation bar.
struct HeroGradientBackground: View {
    let color: HearthRGBColor?
    var height: CGFloat = 520
    /// Full-bleed (podcast / episode headers) instead of a soft tint.
    var solid = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let base = color?.color ?? Color.hearthTint.opacity(solid ? 0.6 : 0.35)
        let stops: [Gradient.Stop] = if solid {
            [
                .init(color: base, location: 0),
                .init(color: base, location: 0.72),
                .init(color: base.opacity(0), location: 1),
            ]
        } else {
            [
                .init(color: base.opacity(colorScheme == .dark ? 0.75 : 0.55), location: 0),
                .init(color: base.opacity(colorScheme == .dark ? 0.35 : 0.25), location: 0.5),
                .init(color: base.opacity(0), location: 1),
            ]
        }
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Places a hero gradient behind a scroll view that moves with the content (and stretches on overscroll).
    func heroBackground(color: HearthRGBColor?, height: CGFloat, solid: Bool = false) -> some View {
        modifier(HeroBackgroundModifier(color: color, height: height, solid: solid))
    }
}

private struct HeroBackgroundModifier: ViewModifier {
    let color: HearthRGBColor?
    let height: CGFloat
    let solid: Bool

    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                offset = newValue
            }
            .background(alignment: .top) {
                HeroGradientBackground(color: color, height: height + max(0, -offset), solid: solid)
                    .offset(y: -max(0, offset))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
            }
    }
}

/// Color scheme that keeps text readable on top of a solid dominant-color header.
extension HearthRGBColor {
    var headerColorScheme: ColorScheme { isLight ? .light : .dark }

    /// Play button fill that contrasts with a solid header of this color.
    var headerButtonColor: HearthRGBColor {
        isLight
            ? HearthRGBColor(red: red * 0.35, green: green * 0.35, blue: blue * 0.35)
            : HearthRGBColor(red: min(1, red * 0.4 + 0.6), green: min(1, green * 0.4 + 0.6), blue: min(1, blue * 0.4 + 0.6))
    }
}

/// Large circular icon button used in hero headers (glass).
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 50, height: 50)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}
