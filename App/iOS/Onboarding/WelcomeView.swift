import HearthUI
import SwiftUI

/// First launch: app icon, feature bullets, "Add Server" and footer links.
struct WelcomeView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer(minLength: 24)

                VStack(spacing: 18) {
                    HearthAppIcon()
                        .frame(width: 112, height: 112)
                    VStack(spacing: 8) {
                        Text("Welcome to Hearth")
                            .hearthTitle(.largeTitle)
                            .multilineTextAlignment(.center)
                        Text("Your audiobookshelf library, right at home on iPhone and iPad.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                VStack(alignment: .leading, spacing: 22) {
                    FeatureRow(systemImage: "books.vertical.fill", title: "Audiobooks & Podcasts", text: "Browse your libraries, series, authors and collections from all your servers.")
                    FeatureRow(systemImage: "arrow.down.circle.fill", title: "Listen Anywhere", text: "Download for offline listening. Your progress syncs when you're back online.")
                    FeatureRow(systemImage: "moon.zzz.fill", title: "Made for Listening", text: "Chapters, bookmarks, sleep timer, speed control and a queue that plays what's next.")
                    FeatureRow(systemImage: "chart.bar.fill", title: "Daily Goals", text: "Track your listening time and keep your streak going.")
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 8)

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .modifier(CenterInRegularWidth(isRegular: sizeClass == .regular))
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 16) {
                Button {
                    navigator.sheet = .addConnection
                } label: {
                    Label("Add Server", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: 420)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                HStack(spacing: 20) {
                    Link("License", destination: AppLinks.license)
                    Link("Privacy", destination: AppLinks.privacy)
                    Link("Source Code", destination: AppLinks.repository)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background {
            LinearGradient(
                colors: [Color.hearthTint.opacity(0.22), Color.hearthTint.opacity(0.04), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Drawn app mark (flame in a warm rounded square), used until the asset catalog icon is designed.
struct HearthAppIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.98, green: 0.62, blue: 0.27), Color(red: 0.84, green: 0.33, blue: 0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "flame.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.gradient)
                    .padding(26)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
            .shadow(color: Color(red: 0.84, green: 0.33, blue: 0.16).opacity(0.35), radius: 16, y: 8)
            .accessibilityHidden(true)
    }
}

/// External links.
enum AppLinks {
    static let repository = URL(string: "https://github.com/hearth-app/hearth")!
    static let issues = URL(string: "https://github.com/hearth-app/hearth/issues")!
    static let license = URL(string: "https://github.com/hearth-app/hearth/blob/main/LICENSE")!
    static let privacy = URL(string: "https://github.com/hearth-app/hearth/blob/main/PRIVACY.md")!
    static let audiobookshelf = URL(string: "https://www.audiobookshelf.org")!
}

/// On iPad the welcome content fits on screen; center it vertically instead of pinning it to the top.
private struct CenterInRegularWidth: ViewModifier {
    let isRegular: Bool

    func body(content: Content) -> some View {
        if isRegular {
            content.containerRelativeFrame(.vertical, alignment: .center)
        } else {
            content
        }
    }
}
