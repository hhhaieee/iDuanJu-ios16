import Foundation
import Combine

struct WatchProgress: Codable, Hashable, Identifiable {
    var series: HGSeries
    var episodeIndex: Int
    var episodeNumber: Int
    var seconds: Double
    var duration: Double
    var updatedAt: Date
    var id: String { series.id }
    var fraction: Double { duration > 0 ? min(1, seconds / duration) : 0 }
    /// "看到第3集" for dramas, "看到 41:12" for single long videos.
    var resumeLabel: String { series.source.isLongVideo ? "看到 " + Fmt.clock(Int(seconds)) : "看到第\(episodeNumber)集" }
}

/// Local-only watch history + favorites, persisted as JSON in UserDefaults.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var progress: [String: WatchProgress] = [:]
    /// Every favorite incl. hidden sources; UI reads `favorites`, which hides locked/disabled sites.
    @Published private(set) var allFavorites: [HGSeries] = []
    var favorites: [HGSeries] { allFavorites.filter { SourceGate.shared.isVisible($0) } }
    @Published private(set) var searchHistory: [String] = []

    private let d = UserDefaults.standard
    private init() {
        progress = load("stv.progress") ?? [:]
        allFavorites = load("stv.favorites") ?? []
        searchHistory = load("stv.searchHistory") ?? []
    }

    var continueWatching: [WatchProgress] {
        progress.values.filter { SourceGate.shared.isVisible($0.series) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func progress(for s: HGSeries) -> WatchProgress? { progress[s.id] }

    func record(_ s: HGSeries, index: Int, ep: Int, seconds: Double, duration: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        progress[s.id] = WatchProgress(series: s, episodeIndex: index, episodeNumber: ep, seconds: seconds,
                                       duration: duration.isFinite ? duration : 0, updatedAt: Date())
        save(progress, "stv.progress")
    }

    func removeProgress(_ s: HGSeries) { progress[s.id] = nil; save(progress, "stv.progress") }
    /// Clears the visible history (hidden / locked sources keep theirs, like continueWatching).
    func clearHistory() {
        for p in continueWatching { progress[p.series.id] = nil }
        save(progress, "stv.progress")
    }

    func isFavorite(_ s: HGSeries) -> Bool { allFavorites.contains { $0.id == s.id } }

    func toggleFavorite(_ s: HGSeries) {
        if isFavorite(s) { allFavorites.removeAll { $0.id == s.id } } else { allFavorites.insert(s, at: 0) }
        save(allFavorites, "stv.favorites")
    }

    func addSearch(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        searchHistory.removeAll { $0 == t }; searchHistory.insert(t, at: 0)
        searchHistory = Array(searchHistory.prefix(10)); save(searchHistory, "stv.searchHistory")
    }
    func removeSearch(_ q: String) { searchHistory.removeAll { $0 == q }; save(searchHistory, "stv.searchHistory") }
    func clearSearch() { searchHistory = []; save(searchHistory, "stv.searchHistory") }

    private func load<T: Decodable>(_ k: String) -> T? { d.data(forKey: k).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private func save<T: Encodable>(_ v: T, _ k: String) { if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: k) } }
}
