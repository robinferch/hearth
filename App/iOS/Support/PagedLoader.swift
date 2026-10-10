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
    private var fetch: Fetch
    private var nextPage = 0
    private var generation = 0

    init(pageSize: Int = 100, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    var hasMore: Bool {
        guard let total else { return true }
        return items.count < total
    }

    /// Replaces the fetch closure (e.g. new sort/filter) and reloads from the first page.
    func reset(fetch: @escaping Fetch) async {
        self.fetch = fetch
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
            items = replacing ? result.items : items + result.items
            total = result.total
            nextPage = page + 1
            hasLoaded = true
            if result.items.isEmpty {
                total = items.count
            }
        } catch {
            guard token == generation else { return }
            if replacing {
                items = []
            }
            self.error = error
            hasLoaded = true
        }
    }
}

/// Convenience accessors.
@MainActor
enum Client {
    static func `for`(_ connectionID: ConnectionID) throws -> any AudiobookshelfClient {
        try HearthData.shared.connections.client(for: connectionID)
    }
}
