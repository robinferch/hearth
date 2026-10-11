import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Author or narrator page (`id.kind` is `.author` or `.narrator`): avatar, name, description, series (authors)
/// and audiobooks.
struct PersonDetailView: View {
    let id: ItemIdentifier

    @State private var loader: DetailLoader<PersonContent>

    init(id: ItemIdentifier) {
        self.id = id
        _loader = State(initialValue: DetailLoader {
            let client = try Client.for(id.connectionID)
            if id.kind == .narrator {
                let result = try await client.narrator(id)
                return PersonContent(person: result.narrator, audiobooks: result.audiobooks, series: [])
            }
            let result = try await client.author(id)
            let books = result.audiobooks.sorted { lhs, rhs in
                let left = lhs.released ?? "9999"
                let right = rhs.released ?? "9999"
                return left == right ? lhs.sortName < rhs.sortName : left < right
            }
            HearthData.shared.items.remember(books.map(AnyItem.audiobook))
            return PersonContent(person: result.author, audiobooks: books, series: result.series)
        })
    }

    var body: some View {
        LoadStateView(loader.state, retry: { await loader.reload() }) { content in
            PersonDetailContent(content: content) {
                HearthData.shared.items.invalidate(id)
                await loader.reload()
            }
        }
        .itemUserActivity(id, title: loader.value?.person.name)
        .task {
            if loader.value == nil {
                await loader.reload()
            }
        }
    }
}

struct PersonContent {
    var person: Person
    var audiobooks: [Audiobook]
    var series: [Series]
}

private struct PersonDetailContent: View {
    let content: PersonContent
    let refresh: @MainActor () async -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var displayMode: DisplayMode = HearthData.shared.itemSettings.displayMode(for: "detail.person")
    @State private var filter: ProgressFilter = .all

    private var person: Person { content.person }
    private var isNarrator: Bool { person.id.kind == .narrator }

    private var books: [Audiobook] {
        guard filter != .all else { return content.audiobooks }
        return content.audiobooks.filter { ProgressFilterMatcher.matches(filter, id: $0.id) }
    }

    var body: some View {
        let books = books
        List {
            header
                .detailPlainRow(insets: EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))

            if !content.series.isEmpty {
                Section {
                    Group {
                        DetailSectionTitle(title: String(localized: "Series", table: "Detail"))
                    }
                    .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(content.series) { series in
                                DetailLink(value: .item(series.id)) {
                                    SeriesGridCell(series: series)
                                        .frame(width: sizeClass == .compact ? 128 : 160)
                                }
                                .buttonStyle(.plain)
                                .itemActions(for: .series(series))
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, 20, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .detailPlainRow(insets: EdgeInsets(top: 4, leading: 0, bottom: 16, trailing: 0))
                }
                .listRowBackground(Color.clear)
            }

            Section {
                Group {
                    DetailSectionTitle(title: String(localized: "Audiobooks", table: "Detail"))
                }
                .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
                if books.isEmpty {
                    Text("No books match the current filter.", tableName: "Detail")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if displayMode == .grid {
                    LazyVGrid(columns: AdaptiveGrid.columns(compact: sizeClass == .compact, minimumCompact: 140, minimumRegular: 170), spacing: 20) {
                        ForEach(books) { book in
                            DetailLink(value: .item(book.id)) {
                                AudiobookGridCell(audiobook: book)
                            }
                            .buttonStyle(.plain)
                            .itemActions(for: .audiobook(book), swipeActions: false, context: isNarrator ? .standard : .authorPage)
                        }
                    }
                    .detailPlainRow(insets: EdgeInsets(top: 8, leading: 20, bottom: 20, trailing: 20))
                } else {
                    ForEach(books) { book in
                        NavigationLink(value: NavigationDestination.item(book.id)) {
                            AudiobookRow(audiobook: book, secondary: isNarrator ? .authorsAndNarrators : .series)
                        }
                        .itemActions(for: .audiobook(book), context: isNarrator ? .standard : .authorPage)
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .heroBackground(color: nil, height: 420)
        .detailNavigationTitle(person.name, threshold: 260)
        .refreshable { await refresh() }
        .onChange(of: displayMode) { _, mode in
            HearthData.shared.itemSettings.setDisplayMode(mode, for: "detail.person")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    DisplayModeSection(mode: $displayMode)
                    ProgressFilterSection(filter: $filter)
                } label: {
                    Label(String(localized: "Options", table: "Detail"), systemImage: "line.3.horizontal.decrease")
                        .symbolVariant(filter != .all ? .circle.fill : .none)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Group {
                if isNarrator {
                    Image(systemName: "waveform")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, height: 120)
                        .background(.quaternary, in: .circle)
                } else {
                    ItemImage(id: person.id, size: .regular)
                        .frame(width: 120, height: 120)
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                }
            }
            .padding(.top, 12)
            .accessibilityHidden(true)
            Text(person.name)
                .hearthTitle(.title)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(HearthFormat.joined([person.id.kind.localizedName, HearthFormat.bookCount(content.audiobooks.count)]))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if person.descriptionHTML?.isEmpty == false {
                DescriptionView(html: person.descriptionHTML, collapsedLines: 3, expansion: .sheet(title: person.name))
                    .frame(maxWidth: 640)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
