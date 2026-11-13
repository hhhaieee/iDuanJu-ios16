import SwiftUI

@MainActor
final class Pager: ObservableObject {
    @Published var items: [HGSeries] = []
    @Published var hasMore = true
    @Published var isLoading = false
    @Published var error: Error? = nil
    @Published private(set) var page = HGPage(items: [], hasMore: true, nextOffset: 0)
    @Published private var fetch: ((HGPage, [HGSeries]) async throws -> HGPage)? = nil
    @Published private var token = UUID()

    func reset(_ f: @escaping (HGPage, [HGSeries]) async throws -> HGPage) {
        fetch = f; items = []; hasMore = true; error = nil; isLoading = false
        page = HGPage(items: [], hasMore: true, nextOffset: 0); token = UUID()
        loadMore()
    }

    func loadMore() {
        guard let fetch, hasMore, !isLoading else { return }
        isLoading = true
        let t = token, prev = page, seen = items
        Task {
            do {
                let p = try await fetch(prev, seen)
                guard t == token else { return }
                var ids = Set(items.map(\.id))
                items += p.items.filter { ids.insert($0.id).inserted }
                page = p
                hasMore = p.hasMore && !p.items.isEmpty
                error = nil
            } catch {
                guard t == token else { return }
                self.error = error
            }
            if t == token { isLoading = false }
        }
    }
}
