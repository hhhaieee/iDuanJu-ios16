import Foundation
import Combine

/// A book on the shelf. Imported files are converted once to `book.txt` (UTF-8) + chapter ranges, so
/// TXT and EPUB read the same way. Stored under Documents/Novels/<id>/.
struct NovelBook: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var author: String?
    var format: String
    var chapters: [NovelChapter]
    var hasCover: Bool
    var addedAt: Date
    // 书源 books: chapters are fetched on demand and cached under <dir>/ch/<index>.txt.
    var sourceURL: String?
    var bookURL: String?
    var tocURL: String?
    var coverURL: String?
    var chapterURLs: [String]?

    var isWeb: Bool { sourceURL != nil }
}

struct NovelProgress: Codable, Hashable {
    var chapter: Int
    /// UTF-16 offset inside the chapter where the current page starts.
    var offset: Int
    var updatedAt: Date
}

@MainActor
final class NovelStore: ObservableObject {
    static let shared = NovelStore()
    @Published private(set) var books: [NovelBook] = []
    @Published private(set) var progress: [String: NovelProgress] = [:]
    @Published private var textCache: [String: String] = [:]
    private let d = UserDefaults.standard

    private init() {
        books = load("stv.novel.books") ?? []
        progress = load("stv.novel.progress") ?? [:]
    }

    nonisolated static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Novels", isDirectory: true)
    }
    nonisolated static func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    nonisolated static func coverURL(_ id: String) -> URL { dir(id).appendingPathComponent("cover") }

    /// Shelf order: last read first, then newest imports.
    var shelf: [NovelBook] {
        books.sorted { (progress[$0.id]?.updatedAt ?? $0.addedAt) > (progress[$1.id]?.updatedAt ?? $1.addedAt) }
    }

    /// Imports files picked in the document picker (security-scoped URLs). Returns per-file errors.
    func importFiles(_ urls: [URL]) async -> [String] {
        var errors: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent
                let parsed = try await Task.detached(priority: .userInitiated) { try NovelImport.parse(data, fileName: name) }.value
                try add(parsed, format: url.pathExtension.lowercased())
            } catch {
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return errors
    }

    @discardableResult
    func add(_ p: NovelParsed, format: String) throws -> NovelBook {
        let id = UUID().uuidString
        let dir = Self.dir(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(p.text.utf8).write(to: dir.appendingPathComponent("book.txt"))
        if let c = p.cover { try? c.write(to: Self.coverURL(id)) }
        let book = NovelBook(id: id, title: p.title, author: p.author, format: format.isEmpty ? "txt" : format,
            chapters: p.chapters, hasCover: p.cover != nil, addedAt: Date())
        books.insert(book, at: 0)
        save(books, "stv.novel.books")
        return book
    }

    func remove(_ b: NovelBook) {
        books.removeAll { $0.id == b.id }
        progress[b.id] = nil
        textCache[b.id] = nil
        try? FileManager.default.removeItem(at: Self.dir(b.id))
        save(books, "stv.novel.books")
        save(progress, "stv.novel.progress")
    }

    nonisolated static func chapterFile(_ b: NovelBook, _ i: Int) -> URL { dir(b.id).appendingPathComponent("ch/\(i).txt") }

    func isCached(_ b: NovelBook, _ i: Int) -> Bool { !b.isWeb || FileManager.default.fileExists(atPath: Self.chapterFile(b, i).path) }

    func cache(_ b: NovelBook, _ i: Int, _ text: String) {
        let f = Self.chapterFile(b, i)
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: f)
    }

    /// Adds a book found through a 书源 (or returns the one already on the shelf).
    @discardableResult
    func addWeb(_ item: LegadoSearchItem, info: LegadoBookInfo?, toc: [LegadoChapter]) -> NovelBook {
        if let b = webBook(source: item.sourceURL, url: item.bookURL) { return b }
        // Synthetic 1000-character slots keep the shared position maths (fraction, slider) chapter-based.
        let chapters = toc.enumerated().map { NovelChapter(title: $1.title, start: $0 * 1000, end: ($0 + 1) * 1000) }
        var b = NovelBook(id: UUID().uuidString, title: info?.name.isEmpty == false ? info!.name : item.name,
            author: (info?.author).flatMap { $0.isEmpty ? nil : $0 } ?? (item.author.isEmpty ? nil : item.author),
            format: "web", chapters: chapters, hasCover: false, addedAt: Date())
        b.sourceURL = item.sourceURL
        b.bookURL = item.bookURL
        b.tocURL = info?.tocURL ?? item.bookURL
        b.coverURL = (info?.cover).flatMap { $0.isEmpty ? nil : $0 } ?? (item.cover.isEmpty ? nil : item.cover)
        b.chapterURLs = toc.map(\.url)
        try? FileManager.default.createDirectory(at: Self.dir(b.id), withIntermediateDirectories: true)
        books.insert(b, at: 0)
        save(books, "stv.novel.books")
        return b
    }

    func webBook(source: String, url: String) -> NovelBook? { books.first { $0.sourceURL == source && $0.bookURL == url } }

    /// New chapters from a refreshed 目录 (cached text is kept by index).
    func updateToc(_ b: NovelBook, _ toc: [LegadoChapter]) {
        guard let i = books.firstIndex(where: { $0.id == b.id }), !toc.isEmpty else { return }
        books[i].chapters = toc.enumerated().map { NovelChapter(title: $1.title, start: $0 * 1000, end: ($0 + 1) * 1000) }
        books[i].chapterURLs = toc.map(\.url)
        save(books, "stv.novel.books")
    }

    func book(_ id: String) -> NovelBook? { books.first { $0.id == id } }

    func text(_ b: NovelBook) -> String {
        if let t = textCache[b.id] { return t }
        let t = (try? String(contentsOf: Self.dir(b.id).appendingPathComponent("book.txt"), encoding: .utf8)) ?? ""
        textCache = [b.id: t]   // one book at a time; texts can be tens of MB
        return t
    }

    func chapterText(_ b: NovelBook, _ i: Int) -> String {
        guard b.chapters.indices.contains(i) else { return "" }
        if b.isWeb { return (try? String(contentsOf: Self.chapterFile(b, i), encoding: .utf8)) ?? "" }
        let c = b.chapters[i]
        let ns = text(b) as NSString
        guard c.end <= ns.length else { return "" }
        return ns.substring(with: NSRange(location: c.start, length: c.length))
    }

    /// Seconds spent in the reader per book (进度 panel: 阅读时长 / 约 N 小时后读完).
    @Published private(set) var readTime: [String: Double] = (UserDefaults.standard.dictionary(forKey: "stv.novel.readTime") as? [String: Double]) ?? [:]
    func addReadTime(_ b: NovelBook, _ seconds: Double) {
        guard seconds > 1 else { return }
        readTime[b.id, default: 0] += min(seconds, 3600)
        d.set(readTime, forKey: "stv.novel.readTime")
    }

    func record(_ b: NovelBook, chapter: Int, offset: Int) {
        progress[b.id] = NovelProgress(chapter: chapter, offset: offset, updatedAt: Date())
        save(progress, "stv.novel.progress")
    }

    /// 0…1 through the whole book (by characters).
    func fraction(_ b: NovelBook) -> Double? {
        guard let p = progress[b.id], let last = b.chapters.last, last.end > 0, b.chapters.indices.contains(p.chapter) else { return nil }
        if b.isWeb { return Double(p.chapter + 1) / Double(b.chapters.count) }
        return min(1, Double(b.chapters[p.chapter].start + p.offset) / Double(last.end))
    }

    private func load<T: Decodable>(_ key: String) -> T? { d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private func save<T: Encodable>(_ v: T, _ key: String) { d.set(try? JSONEncoder().encode(v), forKey: key) }
}

/// Reader appearance, after WeRead: size, margins, line spacing, paper colour, typeface, indent, page turning.
@MainActor
final class NovelPrefs: ObservableObject {
    static let shared = NovelPrefs()
    enum Theme: Int, CaseIterable { case white, cream, green, night }

    var fontSize: Double { didSet { d.set(fontSize, forKey: "stv.novel.font") } }
    /// 0 = 紧 … 1 = 松
    var lineSpacing: Double { didSet { d.set(lineSpacing, forKey: "stv.novel.lineSpacing") } }
    /// 0 = 小 … 1 = 大
    var margin: Double { didSet { d.set(margin, forKey: "stv.novel.margin") } }
    var theme: Theme { didSet { d.set(theme.rawValue, forKey: "stv.novel.theme") } }
    var turn: NovelTurnStyle { didSet { d.set(turn.rawValue, forKey: "stv.novel.turnStyle") } }
    /// `NovelFonts.all` id.
    var fontID: String { didSet { d.set(fontID, forKey: "stv.novel.fontID") } }
    var indent: Bool { didSet { d.set(indent, forKey: "stv.novel.indent") } }
    private let d = UserDefaults.standard

    private init() {
        fontSize = d.object(forKey: "stv.novel.font") as? Double ?? 18
        lineSpacing = d.object(forKey: "stv.novel.lineSpacing") as? Double ?? 0.5
        margin = d.object(forKey: "stv.novel.margin") as? Double ?? 0.3
        theme = Theme(rawValue: d.integer(forKey: "stv.novel.theme")) ?? .white
        turn = (d.object(forKey: "stv.novel.turnStyle") as? Int).flatMap(NovelTurnStyle.init(rawValue:)) ?? .slide
        fontID = d.string(forKey: "stv.novel.fontID") ?? "system"
        indent = d.object(forKey: "stv.novel.indent") as? Bool ?? true
    }
}
