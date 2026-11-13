import Foundation
import Combine

struct MangaProgress: Codable, Hashable {
    var item: MangaItem
    var chapterId: String
    var chapterTitle: String
    var chapterIndex: Int
    var page: Int
    var pageCount: Int
    var updatedAt: Date
}

/// Downloaded chapter: pages saved as files under Documents/Manga/<source>/<manga>/<chapter>/.
struct MangaOffline: Codable, Hashable {
    enum State: String, Codable { case running, done, failed }
    var item: MangaItem
    var chapter: MangaChapter
    var files: [String] = []
    var total: Int = 0
    var state: State = .running
    var error: String? = nil
}

/// Favorites, reading progress and offline chapters (local only).
@MainActor
final class MangaStore: ObservableObject {
    static let shared = MangaStore()
    @Published private(set) var favorites: [MangaItem] = []
    @Published private(set) var progress: [String: MangaProgress] = [:]
    @Published private(set) var offline: [String: MangaOffline] = [:]
    @Published private var tasks: [String: Task<Void, Never>] = [:]
    private let d = UserDefaults.standard

    private init() {
        if MangaFixtures.provider != nil { return }   // DEBUG fixture runs: in-memory only
        favorites = load("stv.manga.favorites") ?? []
        progress = load("stv.manga.progress") ?? [:]
        offline = (load("stv.manga.offline") as [String: MangaOffline]?)?.mapValues { var o = $0; if o.state == .running { o.state = .failed; o.error = "已中断" }; return o } ?? [:]
    }

    static func key(_ m: MangaItem, _ c: MangaChapter) -> String { m.id + "#" + c.chapterId }

    // MARK: Favorites / progress

    func isFavorite(_ m: MangaItem) -> Bool { favorites.contains { $0.id == m.id } }
    func toggleFavorite(_ m: MangaItem) {
        if isFavorite(m) { favorites.removeAll { $0.id == m.id } } else { favorites.insert(m, at: 0) }
        save(favorites, "stv.manga.favorites")
    }

    func record(_ m: MangaItem, _ c: MangaChapter, page: Int, of n: Int) {
        progress[m.id] = MangaProgress(item: m, chapterId: c.chapterId, chapterTitle: c.title, chapterIndex: c.index, page: page, pageCount: n, updatedAt: Date())
        save(progress, "stv.manga.progress")
    }
    var recent: [MangaProgress] { progress.values.sorted { $0.updatedAt > $1.updatedAt } }

    // MARK: Offline chapters

    nonisolated static var root: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Manga", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    nonisolated static func dir(_ m: MangaItem, _ c: MangaChapter) -> URL {
        let safe = { (s: String) in String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }) }
        return root.appendingPathComponent(m.source.rawValue).appendingPathComponent(safe(m.mangaId)).appendingPathComponent(safe(c.chapterId))
    }

    func offlineState(_ m: MangaItem, _ c: MangaChapter) -> MangaOffline? { offline[Self.key(m, c)] }

    /// Local file URLs when the chapter is fully downloaded.
    func localPages(_ m: MangaItem, _ c: MangaChapter) -> [String]? {
        guard let o = offline[Self.key(m, c)], o.state == .done, !o.files.isEmpty else { return nil }
        let dir = Self.dir(m, c)
        return o.files.map { dir.appendingPathComponent($0).absoluteString }
    }

    func download(_ m: MangaItem, _ c: MangaChapter) {
        let k = Self.key(m, c)
        guard tasks[k] == nil, offline[k]?.state != .done else { return }
        offline[k] = MangaOffline(item: m, chapter: c)
        persistOffline()
        tasks[k] = Task {
            do {
                let p = m.source.provider
                let urls = try await p.pages(m, c)
                offline[k]?.total = urls.count
                let dir = Self.dir(m, c)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var files: [String] = []
                for (i, u) in urls.enumerated() {
                    try Task.checkCancellation()
                    let ext = u.hasPrefix(PluginMedia.scheme) ? "jpg" : URL(string: u)?.pathExtension.lowercased()
                    let name = String(format: "%04d.", i) + (ext.map { ["jpg", "jpeg", "png", "webp", "gif"].contains($0) ? $0 : "jpg" } ?? "jpg")
                    let dest = dir.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        let data = u.hasPrefix(PluginMedia.scheme) ? try await PluginMedia.load(u) : try await MangaHTTP.get(u, headers: p.imageHeaders).0
                        try data.write(to: dest, options: .atomic)
                    }
                    files.append(name)
                    offline[k]?.files = files
                }
                offline[k]?.state = .done
            } catch is CancellationError {
                offline[k] = nil
            } catch {
                offline[k]?.state = .failed; offline[k]?.error = error.localizedDescription
            }
            tasks[k] = nil
            persistOffline()
        }
    }

    func deleteOffline(_ m: MangaItem, _ c: MangaChapter) {
        let k = Self.key(m, c)
        tasks.removeValue(forKey: k)?.cancel()
        try? FileManager.default.removeItem(at: Self.dir(m, c))
        offline[k] = nil
        persistOffline()
    }

    var offlineList: [MangaOffline] { offline.values.sorted { ($0.item.title, $0.chapter.index) < ($1.item.title, $1.chapter.index) } }

    private func persistOffline() { save(offline, "stv.manga.offline") }
    private func load<T: Decodable>(_ k: String) -> T? { d.data(forKey: k).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private func save<T: Encodable>(_ v: T, _ k: String) { if MangaFixtures.provider != nil { return }; if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: k) } }
}
