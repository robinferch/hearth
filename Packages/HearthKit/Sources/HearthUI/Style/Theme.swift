import HearthData
import HearthModel
import SwiftUI

// MARK: - Tint colors

public extension TintColor {
    /// The app-wide tint (`.tint(_:)`).
    var color: Color {
        switch self {
        // #E87A2E – warm amber / ember.
        case .hearth: Color(red: 0.910, green: 0.478, blue: 0.180)
        case .yellow: Color(red: 0.95, green: 0.72, blue: 0.10)
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .blue: .blue
        case .teal: Color(red: 0.16, green: 0.64, blue: 0.66)
        case .mint: .mint
        case .green: .green
        case .graphite: Color(red: 0.45, green: 0.46, blue: 0.50)
        }
    }

    /// Secondary color paired with the tint (e.g. "Add to queue" swipe action, chart accents).
    var accent: Color {
        switch self {
        // #B5452A – deep ember.
        case .hearth: Color(red: 0.710, green: 0.271, blue: 0.165)
        case .yellow: .orange
        case .red: Color(red: 0.75, green: 0.16, blue: 0.30)
        case .pink: .purple
        case .purple: .indigo
        case .blue: .cyan
        case .teal: .blue
        case .mint: .teal
        case .green: .mint
        case .graphite: Color(red: 0.30, green: 0.31, blue: 0.34)
        }
    }

    var localizedName: String {
        switch self {
        case .hearth: loc("Hearth")
        case .yellow: loc("Yellow")
        case .red: loc("Red")
        case .pink: loc("Pink")
        case .purple: loc("Purple")
        case .blue: loc("Blue")
        case .teal: loc("Teal")
        case .mint: loc("Mint")
        case .green: loc("Green")
        case .graphite: loc("Graphite")
        }
    }
}

public extension ColorSchemePreference {
    /// `nil` follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var localizedName: String {
        switch self {
        case .system: loc("System")
        case .light: loc("Light")
        case .dark: loc("Dark")
        }
    }
}

public extension HearthRGBColor {
    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Readable foreground on top of this color.
    var contrastingForeground: Color { isLight ? .black : .white }
}

// MARK: - Environment

public extension Color {
    /// The user's current tint color (`AppSettings.tintColor`). Prefer `.tint` shape styles in views;
    /// use this where a concrete `Color` is needed (gradients, glass tints).
    @MainActor
    static var hearthTint: Color { AppSettings.shared.tintColor.color }
}

public extension EnvironmentValues {
    /// Paired accent of the user's tint color.
    @Entry var hearthAccent: Color = TintColor.hearth.accent
}

// MARK: - Serif titles

/// Applies the title font, honoring `AppSettings.serifTitles`.
public struct HearthTitleModifier: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight

    public func body(content: Content) -> some View {
        let serif = AppSettings.shared.serifTitles
        content.font(.system(style, design: serif ? .serif : .default, weight: weight))
    }
}

public extension View {
    /// Title font that switches to a serif design when `AppSettings.serifTitles` is on.
    func hearthTitle(_ style: Font.TextStyle = .title, weight: Font.Weight = .bold) -> some View {
        modifier(HearthTitleModifier(style: style, weight: weight))
    }
}

// MARK: - Dominant color

/// Loads the dominant color of an item's cover (`ImageStore.dominantColor`).
public struct DominantColorReader<Content: View>: View {
    let id: ItemIdentifier?
    let content: (HearthRGBColor?) -> Content

    @State private var color: HearthRGBColor?

    public init(id: ItemIdentifier?, @ViewBuilder content: @escaping (HearthRGBColor?) -> Content) {
        self.id = id
        self.content = content
    }

    public var body: some View {
        content(color)
            .task(id: id) {
                guard let id else {
                    color = nil
                    return
                }
                let value = await HearthData.shared.images.dominantColor(for: id)
                withAnimation(.smooth) {
                    color = value
                }
            }
    }
}

/// Vertical gradient from the cover's dominant color into the background.
public struct DominantColorGradient: View {
    let color: HearthRGBColor?
    let fallback: Color?

    public init(color: HearthRGBColor?, fallback: Color? = nil) {
        self.color = color
        self.fallback = fallback
    }

    public var body: some View {
        let base = color?.color ?? (fallback ?? .hearthTint).opacity(0.35)
        LinearGradient(
            stops: [
                .init(color: base, location: 0),
                .init(color: base.opacity(0.55), location: 0.45),
                .init(color: base.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

public extension View {
    /// Places a dominant-color gradient for `id` behind the view.
    func dominantColorBackground(for id: ItemIdentifier?, fallback: Color? = nil) -> some View {
        background {
            DominantColorReader(id: id) { color in
                DominantColorGradient(color: color, fallback: fallback)
                    .ignoresSafeArea()
            }
        }
    }
}
