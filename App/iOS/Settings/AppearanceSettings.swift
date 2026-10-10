import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Tint color, color scheme, serif titles, progress %, image quality.
struct AppearanceSettingsView: View {
    var body: some View {
        @Bindable var settings = AppSettings.shared
        Form {
            Section("Tint Color") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 12)], spacing: 14) {
                    ForEach(TintColor.allCases, id: \.self) { tint in
                        Button {
                            withAnimation(.smooth) { settings.tintColor = tint }
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(
                                            AngularGradient(colors: [tint.color, tint.accent, tint.color], center: .center)
                                        )
                                        .frame(width: 40, height: 40)
                                    if settings.tintColor == tint {
                                        Circle()
                                            .strokeBorder(.background, lineWidth: 3)
                                            .frame(width: 40, height: 40)
                                        Circle()
                                            .strokeBorder(tint.color, lineWidth: 2)
                                            .frame(width: 48, height: 48)
                                    }
                                }
                                .frame(width: 48, height: 48)
                                Text(tint.localizedName)
                                    .font(.caption2)
                                    .foregroundStyle(settings.tintColor == tint ? .primary : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tint.localizedName)
                        .accessibilityAddTraits(settings.tintColor == tint ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                Picker("Color Scheme", selection: $settings.colorScheme) {
                    ForEach(ColorSchemePreference.allCases, id: \.self) { scheme in
                        Text(scheme.localizedName).tag(scheme)
                    }
                }
            }

            Section {
                Toggle("Serif Titles", isOn: $settings.serifTitles)
                Toggle("Show Progress as Percentage", isOn: $settings.showProgressPercent)
                Toggle("High-Quality Images", isOn: $settings.highQualityImages)
            } footer: {
                Text("High-quality images use more data and storage.")
            }

            Section("Preview") {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(settings.tintColor.color.gradient)
                        .frame(width: 56, height: 56)
                        .overlay {
                            Image(systemName: "book.closed.fill")
                                .foregroundStyle(.white)
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The Hearth and the Hollow Hills")
                            .hearthTitle(.headline)
                        Text(settings.showProgressPercent ? "42 %" : String(localized: "3h 12m left"))
                            .font(.caption.smallCaps())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressRing(progress: 0.42)
                        .frame(width: 22, height: 22)
                }
            }
        }
        .navigationTitle("Appearance")
    }
}
