import HearthAPI
import HearthData
import HearthModel
import HearthUI
import Observation
import SwiftUI

/// Watch row for books and episodes: cover, title, subtitle, progress.
struct WatchItemRow: View {
    let id: ItemIdentifier
    let title: String
    let subtitle: String?
    var coverSize: CGFloat = 36

    init(item: AnyPlayableItem) {
        id = item.id
        title = item.name
        subtitle = switch item {
        case .audiobook(let audiobook): audiobook.authorLine
        case .episode(let episode): episode.publishedAt.map { HearthFormat.releaseDate($0) } ?? episode.podcastName
        }
    }

    init(audiobook: Audiobook) {
        self.init(item: .audiobook(audiobook))
    }

    init(id: ItemIdentifier, title: String, subtitle: String?, coverSize: CGFloat = 36) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coverSize = coverSize
    }

    var body: some View {
        let status = ItemStatus.of(id)
        HStack(spacing: 8) {
            ItemImage(id: id, size: .tiny, cornerRadius: 5)
                .frame(width: coverSize, height: coverSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if status.isInProgress {
                    ProgressCapsule(progress: status.fraction, height: 3)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Finished")
            } else if status.isDownloading {
                DownloadProgressRing(progress: status.downloadProgress, lineWidth: 2)
                    .frame(width: 16, height: 16)
            } else if status.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Row for series, authors and podcasts.
struct WatchGroupRow: View {
    let id: ItemIdentifier
    let coverID: ItemIdentifier?
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            ItemImage(id: coverID, size: .tiny, cornerRadius: 5, placeholderSymbol: id.kind.systemImage)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Infinite-scroll loader for paged library endpoints.
@MainActor
@Observable
final class WatchPagedLoader<Element: Identifiable & Sendable> {
    typealias Fetch = @MainActor (_ page: Int, _ limit: Int) async throws -> Page<Element>

    private(set) var items: [Element] = []
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var error: (any Error)?
    private(set) var hasLoaded = false

    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var nextPage = 0

    init(pageSize: Int = 40, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    var hasMore: Bool {
        guard let total else { return true }
        return items.count < total
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load(replacing: true)
    }

    func reload() async {
        nextPage = 0
        await load(replacing: true)
    }

    func loadMore(after element: Element) async {
        guard hasMore, !isLoading, error == nil, items.last?.id == element.id else { return }
        await load(replacing: false)
    }

    /// Retries the page that failed (the "Retry" row at the end of the list).
    func retryNextPage() async {
        guard !isLoading else { return }
        error = nil
        await load(replacing: items.isEmpty)
    }

    private func load(replacing: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page = replacing ? 0 : nextPage
        do {
            let result = try await fetch(page, pageSize)
            if replacing {
                items = Self.unique(result.items, excluding: [])
            } else {
                // Pages shift when items change on the server meanwhile; drop repeated ids.
                items += Self.unique(result.items, excluding: Set(items.map(\.id)))
            }
            total = result.items.isEmpty ? items.count : result.total
            nextPage = page + 1
            error = nil
            hasLoaded = true
        } catch {
            // A cancelled request (the view went away) is retried on the next appearance.
            if !Self.isCancellation(error) {
                self.error = error
            }
        }
    }

    private static func unique(_ elements: [Element], excluding existing: Set<Element.ID>) -> [Element] {
        var seen = existing
        return elements.filter { seen.insert($0.id).inserted }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError || (error as? APIError) == .cancelled {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }
}

/// Wraps a paged list with loading, error and empty states.
struct PagedList<Element: Identifiable & Sendable, Row: View>: View {
    let loader: WatchPagedLoader<Element>
    let emptyTitle: LocalizedStringKey
    @ViewBuilder let row: (Element) -> Row

    var body: some View {
        Group {
            if loader.items.isEmpty {
                if let error = loader.error {
                    WatchErrorView(error: error) { await loader.reload() }
                } else if loader.hasLoaded {
                    ContentUnavailableView(emptyTitle, systemImage: "tray")
                } else {
                    ProgressView()
                }
            } else {
                List {
                    ForEach(loader.items) { element in
                        row(element)
                            // Not `.task`: scrolling the row away would cancel the page request.
                            .onAppear { Task { await loader.loadMore(after: element) } }
                    }
                    if loader.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    } else if loader.error != nil {
                        Button {
                            Task { await loader.retryNextPage() }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .task { await loader.loadIfNeeded() }
    }
}

/// Compact error state with retry.
struct WatchErrorView: View {
    let error: any Error
    let retry: @MainActor () async -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Content Unavailable")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await retry() }
                }
            }
            .scenePadding(.horizontal)
        }
    }

    private var message: String {
        if let error = error as? APIError {
            return error.watchMessage
        }
        return String(localized: "Make sure your watch can reach your server.")
    }
}

/// Resolves the API client for a connection.
@MainActor
enum WatchClient {
    static func `for`(_ id: ConnectionID) throws -> any AudiobookshelfClient {
        try HearthData.shared.connections.client(for: id)
    }
}
