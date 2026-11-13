import Foundation
import Combine

/// Fetches 书源 chapters on demand (and the next ones ahead of the reader), caching them on disk.
@MainActor
final class NovelWebLoader: ObservableObject {
    static let shared = NovelWebLoader()
    /// Bumped whenever a chapter arrives or fails, so open readers re-paginate.
    @Published private(set) var revision = 0
    @Published private(set) var failed: [String: String] = [:]
    @Published private var running: Set<String> = []
    private let store = NovelStore.shared

    private func key(_ b: NovelBook, _ i: Int) -> String { b.id + "#" + String(i) }

    func error(_ b: NovelBook, _ i: Int) -> String? { failed[key(b, i)] }
    func isLoading(_ b: NovelBook, _ i: Int) -> Bool { running.contains(key(b, i)) }

    func ensure(_ b: NovelBook, _ i: Int) {
        guard b.isWeb, b.chapters.indices.contains(i), !store.isCached(b, i) else { return }
        let k = key(b, i)
        guard !running.contains(k), failed[k] == nil else { return }
        guard let source = LegadoSourceStore.shared.source(b.sourceURL ?? ""), let urls = b.chapterURLs, urls.indices.contains(i) else {
            failed[k] = "书源已删除，无法加载"
            revision += 1
            return
        }
        running.insert(k)
        let chapter = LegadoChapter(title: b.chapters[i].title, url: urls[i])
        let next = urls.indices.contains(i + 1) ? urls[i + 1] : nil
        let bookInfo: [String: Any] = ["name": b.title, "author": b.author ?? "", "bookUrl": b.bookURL ?? "", "tocUrl": b.tocURL ?? ""]
        nonisolated(unsafe) let info = bookInfo
        Task {
            do {
                let text = try await LegadoClient.run { try LegadoClient.content(source, chapter: chapter, nextChapterURL: next, book: info) }
                // Chapter heading first, like imported books, so the reader styles it.
                let full = text.hasPrefix(chapter.title) ? text : chapter.title + "\n" + text
                store.cache(b, i, full)
            } catch {
                failed[k] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            running.remove(k)
            revision += 1
        }
    }

    func retry(_ b: NovelBook, _ i: Int) {
        failed[key(b, i)] = nil
        ensure(b, i)
        revision += 1
    }

    /// Current chapter plus the next two.
    func prefetch(_ b: NovelBook, around i: Int) {
        for j in i...(i + 2) { ensure(b, j) }
    }

    /// Re-reads the 目录 (new chapters of an ongoing book). Returns the new chapter count.
    func refreshToc(_ b: NovelBook) async throws -> Int {
        guard let source = LegadoSourceStore.shared.source(b.sourceURL ?? ""), let toc = b.tocURL else { return b.chapters.count }
        let list = try await LegadoClient.run { try LegadoClient.toc(source, tocURL: toc) }
        if list.count >= b.chapters.count { store.updateToc(b, list) }
        return list.count
    }
}
