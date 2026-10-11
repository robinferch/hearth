import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Filter / sort menu content for a podcast's episodes (persisted per podcast).
struct EpisodeListOptionsMenu: View {
    @Binding var settings: EpisodeListSettings

    var body: some View {
        Section {
            Picker(selection: $settings.filter) {
                ForEach([ProgressFilter.all, .notStarted, .inProgress, .notFinished, .finished], id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            } label: {
                Text("Show", tableName: "Detail")
            }
            .pickerStyle(.inline)
            Toggle(isOn: $settings.downloadedOnly) {
                Label(String(localized: "Downloaded Only", table: "Detail"), systemImage: "arrow.down.circle")
            }
        }
        Section {
            ForEach(EpisodeSortOrder.allCases, id: \.self) { order in
                Button {
                    if settings.sort == order {
                        settings.direction.toggle()
                    } else {
                        settings.sort = order
                    }
                } label: {
                    if settings.sort == order {
                        Label(order.title, systemImage: settings.direction.isDescending ? "chevron.down" : "chevron.up")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } header: {
            Text("Sort By", tableName: "Detail")
        }
    }
}

/// Toolbar button showing `EpisodeListOptionsMenu`.
struct EpisodeListOptionsButton: View {
    @Binding var settings: EpisodeListSettings

    var body: some View {
        Menu {
            EpisodeListOptionsMenu(settings: $settings)
        } label: {
            Label(String(localized: "Filter & Sort", table: "Detail"), systemImage: "line.3.horizontal.decrease")
                .symbolVariant(settings.filter != .all || settings.downloadedOnly ? .circle.fill : .none)
        }
        .menuActionDismissBehavior(.disabled)
    }
}

/// "Season 2" / "All Seasons" picker menu.
struct SeasonMenu: View {
    let seasons: [String]
    @Binding var selection: String?

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                Text("All Seasons", tableName: "Detail").tag(String?.none)
                ForEach(seasons, id: \.self) { season in
                    Text(SeasonFormat.title(season)).tag(String?.some(season))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(selection.map(SeasonFormat.title) ?? String(localized: "All Seasons", table: "Detail"))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel(String(localized: "Season", table: "Detail"))
        .accessibilityValue(selection.map(SeasonFormat.title) ?? String(localized: "All Seasons", table: "Detail"))
    }
}

enum SeasonFormat {
    static func title(_ season: String) -> String {
        String(localized: "Season \(season)", table: "Detail")
    }
}
