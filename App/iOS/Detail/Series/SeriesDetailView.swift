import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Series page: fanned covers, title, "play first unfinished" and the books (grid or list) with sequence numbers.
struct SeriesDetailView: View {
    let id: ItemIdentifier

    @State private var loader: DetailLoader<Series>

    init(id: ItemIdentifier) {
        self.id = id
        _loader = State(initialValue: DetailLoader {
            guard case .series(let series) = try await HearthData.shared.items.item(id) else {
                throw APIError.notFound
            }
            return series
        })
    }

    var body: some View {
        LoadStateView(loader.state, retry: { await loader.reload() }) { series in
            SeriesDetailContent(series: series) {
                HearthData.shared.items.invalidate(id)
                await loader.reload()
            }
        }
        .itemUserActivity(id, title: loader.value?.name)
        .task {
            if loader.value == nil {
                await loader.reload()
            }
        }
    }
}

private struct SeriesDetailContent: View {
    let series: Series
    let refresh: @MainActor () async -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.itemActionHandler) private var handler
    @Environment(AlertCenter.self) private var alerts
    @Environment(PlayerPresentation.self) private var presentation

    @State private var displayMode: DisplayMode = HearthData.shared.itemSettings.displayMode(for: "detail.series")
    @State private var filter: ProgressFilter = .all
    @State private var isConfiguring = false
    @State private var dominantColor: HearthRGBColor?

    private var books: [Audiobook] {
        guard filter != .all else { return series.audiobooks }
        return series.audiobooks.filter { ProgressFilterMatcher.matches(filter, id: $0.id) }
    }

    private var firstUnfinished: Audiobook? {
        series.audiobooks.first { !HearthData.shared.progress.isFinished($0.id) } ?? series.audiobooks.first
    }

    var body: some View {
        let books = books
        List {
            header
                .detailPlainRow(insets: EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))

            if series.descriptionHTML?.isEmpty == false {
                DescriptionView(html: series.descriptionHTML, collapsedLines: 4, expansion: .sheet(title: series.name))
                    .detailPlainRow(insets: EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
            }

            Section {
                Group {
                    DetailSectionTitle(title: HearthFormat.bookCount(series.audiobooks.count))
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
                                    .overlay(alignment: .topLeading) {
                                        SequenceBadge(sequence: sequence(of: book))
                                    }
                            }
                            .buttonStyle(.plain)
                            .itemActions(for: .audiobook(book), swipeActions: false, context: .seriesPage)
                        }
                    }
                    .detailPlainRow(insets: EdgeInsets(top: 8, leading: 20, bottom: 20, trailing: 20))
                } else {
                    ForEach(books) { book in
                        NavigationLink(value: NavigationDestination.item(book.id)) {
                            AudiobookRow(audiobook: book)
                        }
                        .itemActions(for: .audiobook(book), context: .seriesPage)
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .heroBackground(color: dominantColor, height: 560)
        .detailNavigationTitle(series.name, threshold: 320)
        .environment(\.itemActionHandler, handler.withPlaybackOrigin(.series(series.id), alerts: alerts, presentation: presentation))
        .refreshable { await refresh() }
        .task(id: series.audiobooks.first?.id) {
            guard let first = series.audiobooks.first?.id else { return }
            let color = await HearthData.shared.images.dominantColor(for: first)
            withAnimation(.smooth) { dominantColor = color }
        }
        .onChange(of: displayMode) { _, mode in
            HearthData.shared.itemSettings.setDisplayMode(mode, for: "detail.series")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isConfiguring = true
                } label: {
                    Label(String(localized: "Configure", table: "Detail"), systemImage: "slider.horizontal.3")
                }
                Menu {
                    DisplayModeSection(mode: $displayMode)
                    ProgressFilterSection(filter: $filter)
                } label: {
                    Label(String(localized: "Options", table: "Detail"), systemImage: "line.3.horizontal.decrease")
                        .symbolVariant(filter != .all ? .circle.fill : .none)
                }
            }
        }
        .sheet(isPresented: $isConfiguring) {
            ConfigureSheet(id: series.id, title: series.name)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            FannedCovers(ids: series.audiobooks.map(\.id), fallback: series.id, coverSize: sizeClass == .compact ? 150 : 190, limit: 5)
                .frame(height: sizeClass == .compact ? 190 : 230)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            Text(series.name)
                .font(.system(.title, design: .serif, weight: .bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(HearthFormat.joined([
                series.authors.isEmpty ? nil : series.authors.prefix(3).formatted(.list(type: .and, width: .short)),
                HearthFormat.bookCount(series.audiobooks.count),
                HearthFormat.duration(series.totalDuration ?? series.audiobooks.reduce(0) { $0 + $1.duration }),
            ]))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if let first = firstUnfinished {
                VStack(spacing: 4) {
                    PlayButton(item: .audiobook(first), style: .large, tint: dominantColor)
                        .frame(maxWidth: 380)
                    Text(HearthFormat.joined([sequence(of: first), first.name]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sequence(of book: Audiobook) -> String? {
        let fragment = book.series.first { $0.id == series.id.primaryID } ?? book.series.first
        return HearthFormat.sequence(fragment?.sequence)
    }
}

/// "#3" capsule on grid covers.
struct SequenceBadge: View {
    let sequence: String?

    var body: some View {
        if let sequence {
            Text(sequence)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(6)
                .accessibilityHidden(true)
        }
    }
}

/// Progress filter picker for options menus.
struct ProgressFilterSection: View {
    @Binding var filter: ProgressFilter

    var body: some View {
        Section {
            Picker(selection: $filter) {
                ForEach([ProgressFilter.all, .notStarted, .inProgress, .notFinished, .finished], id: \.self) { value in
                    Text(value.title).tag(value)
                }
            } label: {
                Text("Show", tableName: "Detail")
            }
            .pickerStyle(.inline)
        }
    }
}

/// Client-side progress filtering using the progress store.
@MainActor
enum ProgressFilterMatcher {
    static func matches(_ filter: ProgressFilter, id: ItemIdentifier) -> Bool {
        let progress = HearthData.shared.progress.progress(for: id)
        switch filter {
        case .all: return true
        case .notStarted: return progress == nil || (progress?.progress ?? 0) <= 0
        case .inProgress: return progress?.isInProgress ?? false
        case .finished: return progress?.isFinished ?? false
        case .notFinished: return !(progress?.isFinished ?? false)
        }
    }
}
