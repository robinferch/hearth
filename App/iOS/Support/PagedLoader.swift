import Foundation
import HearthAPI
import HearthData
import HearthModel
import Observation

/// Infinite-scroll loader for paged library endpoints (pages of 100).
@MainActor
@Observable
final class PagedLoader<Element: Identifiable & Sendable> {
    typealias Fetch = @MainActor (_ page: Int, _ limit: Int) async throws -> Page<Element>

    private(set) var items: [Element] = []
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var error: (any Error)?
    private(set) var hasLoaded = false

    let pageSize: Int
    @ObservationIgnored private var fetch: Fetch
    @ObservationIgnored private var nextPage = 0
    @ObservationIgnored private var generation = 0
    /// Identifies the query (sort, filter, …) the current items belong to.
    @ObservationIgnored private var queryKey: AnyHashable?

    init(pageSize: Int = 100, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    var hasMore: Bool {
        guard let total else { return true }
        return items.count < total
    }

    /// Sets the fetch closure for a query (sort, filter, …) and loads its first page – unless that query's items
    /// are already loaded: a view reappearing after a pop keeps its pages (and scroll position). Pull to refresh
    /// uses `reload()`.
    func load(key: some Hashable, fetch: @escaping Fetch) async {
        self.fetch = fetch
        let key = AnyHashable(key)
        if key == queryKey, hasLoaded, error == nil {
            return
        }
        queryKey = key
        await reload()
    }

    func reload() async {
        generation += 1
        nextPage = 0
        total = nil
        error = nil
        isLoading = false
        await loadNextPage(replacing: true)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    /// Call from `.onAppear` of each element; loads the next page near the end.
    func loadMore(ifNeededFor element: Element) async {
        guard hasMore, !isLoading, error == nil else { return }
        let threshold = max(items.count - 20, 0)
        guard let index = items.firstIndex(where: { $0.id == element.id }), index >= threshold else { return }
        await loadNextPage(replacing: false)
    }

    /// Retries the page that failed (the list footer's "Try Again").
    func retryNextPage() async {
        guard error != nil, !isLoading else { return }
        error = nil
        await loadNextPage(replacing: items.isEmpty)
    }

    private func loadNextPage(replacing: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        let token = generation
        let page = nextPage
        defer {
            if token == generation {
                isLoading = false
            }
        }
        do {
            let result = try await fetch(page, pageSize)
            guard token == generation else { return }
            if replacing {
                items = Self.unique(result.items, excluding: [])
            } else {
                // Pages shift when items are added or removed on the server meanwhile; drop repeated ids.
                items += Self.unique(result.items, excluding: Set(items.map(\.id)))
            }
            total = result.total
            nextPage = page + 1
            hasLoaded = true
            if result.items.isEmpty {
                total = items.count
            }
        } catch {
            guard token == generation else { return }
            if Self.isCancellation(error) {
                // The view went away mid-request (task cancelled); the next appearance loads again.
                if replacing {
                    queryKey = nil
                }
                return
            }
            if replacing {
                items = []
            }
            self.error = error
            hasLoaded = true
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

/// Convenience accessors.
@MainActor
enum Client {
    static func `for`(_ connectionID: ConnectionID) throws -> any AudiobookshelfClient {
        try HearthData.shared.connections.client(for: connectionID)
    }
}
