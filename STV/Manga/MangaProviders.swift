import Foundation

/// Comic source: built-in (包子 / MangaDex) or a JS comic plugin (`p.<plugin id>`).
struct MangaSourceID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String
    init?(rawValue: String) {
        guard rawValue == "baozi" || rawValue == "mangadex" || (rawValue.hasPrefix("p.") && rawValue.count > 2) else { return nil }
        self.rawValue = rawValue
    }
    private init(_ raw: String) { rawValue = raw }
    static let baozi = MangaSourceID("baozi")
    static let mangadex = MangaSourceID("mangadex")
    static let builtins: [MangaSourceID] = [.baozi, .mangadex]
    static func plugin(_ id: String) -> MangaSourceID { MangaSourceID("p." + id) }
    /// Built-ins + enabled comic plugins.
    static var allCases: [MangaSourceID] { builtins + PluginStore.comicSources() }
    var pluginID: String? { rawValue.hasPrefix("p.") ? String(rawValue.dropFirst(2)) : nil }

    var id: String { rawValue }
    var label: String {
        switch self {
        case .baozi: "包子漫画"
        case .mangadex: "MangaDex"
        default: pluginID.flatMap { PluginStore.snapshot($0)?.manifest.name } ?? "插件（已移除）"
        }
    }
    var note: String {
        switch self {
        case .baozi: "国漫/日漫/韩漫 · 中文 · 大陆直连（webmota 镜像）"
        case .mangadex: "官方公开 API · 仅全年龄/轻度分级 · 中文+英文章节"
        default: pluginID.flatMap { PluginStore.snapshot($0)?.manifest.description } ?? "JS 插件"
        }
    }
    /// Adult comic plugins are only listed when 片源管理 → 成人漫画 is on (and the lock is open).
    var isAdult: Bool { pluginID.map { PluginStore.snapshot($0)?.manifest.adult ?? true } ?? false }
    var provider: MangaProvider {
        switch self {
        case .baozi: BaoziProvider()
        case .mangadex: MangaDexProvider()
        default: JSComicProvider(source: self)
        }
    }
}

struct MangaItem: Codable, Hashable, Identifiable {
    var source: MangaSourceID
    var mangaId: String
    var title: String
    var cover: String
    var author: String = ""
    var tags: [String] = []
    var latest: String = ""
    var id: String { source.rawValue + ":" + mangaId }
}

struct MangaChapter: Codable, Hashable, Identifiable {
    var chapterId: String
    var title: String
    var index: Int
    var id: String { chapterId }
}

struct MangaDetail: Hashable {
    var item: MangaItem
    var desc: String
    var status: String
    var chapters: [MangaChapter]
}

struct MangaCategory: Hashable, Identifiable { var id: String; var title: String }
struct MangaPage { var items: [MangaItem]; var hasMore: Bool }

protocol MangaProvider: Sendable {
    var source: MangaSourceID { get }
    var categories: [MangaCategory] { get }
    func list(_ c: MangaCategory, page: Int) async throws -> MangaPage
    func search(_ q: String, page: Int) async throws -> MangaPage
    func detail(_ m: MangaItem) async throws -> MangaDetail
    /// Image URLs of one chapter, in reading order.
    func pages(_ m: MangaItem, _ c: MangaChapter) async throws -> [String]
    /// Headers needed to fetch images (Referer etc).
    var imageHeaders: [String: String] { get }
}

enum MangaHTTP {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()
    static func get(_ url: String, headers: [String: String] = [:]) async throws -> (Data, URL) {
        guard let u = URL(string: url) else { throw ProviderError.invalid(url) }
        var r = URLRequest(url: u)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.upstream("HTTP \(code) · \(u.host ?? "")") }
        return (d, resp.url ?? u)
    }
    static func text(_ url: String) async throws -> String { String(decoding: try await get(url).0, as: UTF8.self) }
    static func json(_ url: String, headers: [String: String] = [:]) async throws -> [String: Any] {
        let (d, u) = try await get(url, headers: headers)
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            let head = String(decoding: d.prefix(80), as: UTF8.self)
            throw ProviderError.upstream("\(u.host ?? "") 返回非 JSON：\(head)")
        }
        return o
    }
}

// MARK: - 包子漫画 (baozimh) — own parser of the public mobile pages; mirrors cn.webmota.com etc.

struct BaoziProvider: MangaProvider {
    var source: MangaSourceID { .baozi }
    static let mirrors = ["https://cn.webmota.com", "https://www.webmota.com", "https://cn.baozimh.com", "https://www.baozimh.com"]
    static let coverBase = "https://static-tw.baozimh.com/cover/"
    var imageHeaders: [String: String] { [:] }

    var categories: [MangaCategory] {
        [("all|all", "全部"), ("all|cn", "国漫"), ("all|jp", "日本"), ("all|kr", "韩国"), ("lianai|all", "恋爱"), ("rexie|all", "热血"),
         ("xuanhuan|all", "玄幻"), ("gaoxiao|all", "搞笑"), ("kehuan|all", "科幻"), ("xuanyi|all", "悬疑"), ("gufeng|all", "古风")]
            .map { MangaCategory(id: $0.0, title: $0.1) }
    }

    private func fetch(_ path: String) async throws -> (String, String) {
        var last: Error = ProviderError.upstream("包子漫画不可达")
        for m in Self.mirrors {
            do {
                let (d, final) = try await MangaHTTP.get(m + path)
                let s = String(decoding: d, as: UTF8.self)
                if s.contains("challenge_required") { last = ProviderError.upstream("\(final.host ?? m) 需要人机验证"); continue }
                return (s, "\(final.scheme ?? "https")://\(final.host ?? "")")
            } catch { last = error }
        }
        throw last
    }

    func list(_ c: MangaCategory, page: Int) async throws -> MangaPage {
        let p = c.id.split(separator: "|").map(String.init)
        let (s, _) = try await fetch("/api/bzmhq/amp_comic_list?type=\(p[0])&region=\(p[1])&state=all&filter=*&page=\(page)&limit=36&language=cn")
        return Self.parseList(Data(s.utf8))
    }

    static func parseList(_ d: Data) -> MangaPage {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let items = o["items"] as? [[String: Any]] else { return MangaPage(items: [], hasMore: false) }
        let out = items.compactMap { i -> MangaItem? in
            guard let id = i["comic_id"] as? String, let name = i["name"] as? String else { return nil }
            return MangaItem(source: .baozi, mangaId: id, title: name, cover: coverBase + ((i["topic_img"] as? String) ?? id + ".jpg"),
                             author: (i["author"] as? String) ?? "", tags: (i["type_names"] as? [String]) ?? [])
        }
        return MangaPage(items: out, hasMore: o["next"] is String && !out.isEmpty)
    }

    func search(_ q: String, page: Int) async throws -> MangaPage {
        guard page == 1 else { return MangaPage(items: [], hasMore: false) }
        let (s, _) = try await fetch("/search?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q))
        return MangaPage(items: Self.parseCards(s), hasMore: false)
    }

    static func parseCards(_ s: String) -> [MangaItem] {
        var seen = Set<String>()
        return HTML.all("<a href=\"/comic/([^\"/]+)\" title=\"([^\"]*)\"[^>]*class=\"comics-card__poster[^\"]*\"[^>]*>\\s*<amp-img[^>]*src=\"([^\"]+)\"", s).compactMap { m in
            guard seen.insert(m[1]).inserted else { return nil }
            return MangaItem(source: .baozi, mangaId: m[1], title: HTML.unescape(m[2]), cover: HTML.unescape(m[3]))
        }
    }

    func detail(_ m: MangaItem) async throws -> MangaDetail {
        let (s, _) = try await fetch("/comic/" + m.mangaId)
        return Self.parseDetail(s, item: m)
    }

    static func parseDetail(_ s: String, item: MangaItem) -> MangaDetail {
        var it = item
        let t = HTML.classText(s, "comics-detail__title"); if !t.isEmpty { it.title = t }
        let a = HTML.classText(s, "comics-detail__author"); if !a.isEmpty { it.author = a }
        let tags = HTML.groups("<div class=\"tag-list\"[^>]*>(.*?)</div>", s).map { HTML.all("<span class=\"tag\"[^>]*>([^<]*)</span>", $0[1]).map { HTML.cleanText($0[1]) } } ?? []
        it.tags = tags.filter { !$0.isEmpty }
        let status = it.tags.first { $0.contains("连载") || $0.contains("完结") } ?? ""
        it.tags.removeAll { $0 == status }
        var seen = Set<String>(), chapters: [(Int, Int, String)] = []
        for c in HTML.all("comic_id=[^&\"]+&amp;section_slot=(\\d+)&amp;chapter_slot=(\\d+)\"[^>]*>\\s*<div[^>]*>\\s*<span[^>]*>([^<]*)</span>", s) {
            guard let sec = Int(c[1]), let ch = Int(c[2]), seen.insert("\(sec)_\(ch)").inserted else { continue }
            chapters.append((sec, ch, HTML.cleanText(c[3])))
        }
        chapters.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        let list = chapters.enumerated().map { MangaChapter(chapterId: "\($0.element.0)_\($0.element.1)", title: $0.element.2, index: $0.offset) }
        it.latest = list.last?.title ?? ""
        return MangaDetail(item: it, desc: HTML.classText(s, "comics-detail__desc"), status: status, chapters: list)
    }

    func pages(_ m: MangaItem, _ c: MangaChapter) async throws -> [String] {
        var out: [String] = []
        var path = "/comic/chapter/\(m.mangaId)/\(c.chapterId).html"
        for n in 2...12 {
            let (s, _) = try await fetch(path)
            out += Self.parsePages(s).filter { !out.contains($0) }
            // Long chapters are split into <slot>_2.html, _3.html …
            guard s.contains("/\(m.mangaId)/\(c.chapterId)_\(n).html") else { break }
            path = "/comic/chapter/\(m.mangaId)/\(c.chapterId)_\(n).html"
        }
        guard !out.isEmpty else { throw ProviderError.upstream("本章没有图片（可能需要登录或已下架）") }
        return out
    }

    /// Chapter images; the bzcdn edge often loops redirects, the same path on static-tw answers directly.
    static func parsePages(_ s: String) -> [String] {
        var seen = Set<String>()
        return HTML.all("<amp-img[^>]*id=\"chapter-img-[^\"]*\"[^>]*>", s).compactMap { m in
            let u = HTML.attr(m[0], "data-src", "src")
            guard !u.isEmpty else { return nil }
            let fixed = HTML.replace("^https?://[a-z0-9-]+\\.bzcdn\\.net/", u, "https://static-tw.baozimh.com/")
            return seen.insert(fixed).inserted ? fixed : nil
        }
    }
}

// MARK: - MangaDex — public API (api.mangadex.org), safe + suggestive ratings only.

struct MangaDexProvider: MangaProvider {
    var source: MangaSourceID { .mangadex }
    static let api = "https://api.mangadex.org"
    static let ratings = "contentRating%5B%5D=safe&contentRating%5B%5D=suggestive"
    static let langs = ["zh", "zh-hk", "en"]
    /// MangaDex (api + uploads) 302s browser User-Agents to a bot-challenge page; API clients must
    /// identify themselves with a non-browser UA (per their API docs).
    static let headers = ["User-Agent": "STV/1.4 (iOS; MangaDex API client)"]
    var imageHeaders: [String: String] { Self.headers }

    var categories: [MangaCategory] {
        [("followedCount", "热门"), ("latestUploadedChapter", "最近更新"), ("createdAt", "新作"), ("rating", "高分")].map { MangaCategory(id: $0.0, title: $0.1) }
    }

    func list(_ c: MangaCategory, page: Int) async throws -> MangaPage {
        let off = (page - 1) * 30
        let o = try await MangaHTTP.json("\(Self.api)/manga?limit=30&offset=\(off)&\(Self.ratings)&includes%5B%5D=cover_art&includes%5B%5D=author&availableTranslatedLanguage%5B%5D=zh&availableTranslatedLanguage%5B%5D=zh-hk&order%5B\(c.id)%5D=desc", headers: Self.headers)
        return Self.parseList(o)
    }

    func search(_ q: String, page: Int) async throws -> MangaPage {
        let off = (page - 1) * 30
        let t = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
        let o = try await MangaHTTP.json("\(Self.api)/manga?limit=30&offset=\(off)&title=\(t)&\(Self.ratings)&includes%5B%5D=cover_art&includes%5B%5D=author&order%5Brelevance%5D=desc", headers: Self.headers)
        return Self.parseList(o)
    }

    static func parseList(_ o: [String: Any]) -> MangaPage {
        let data = o["data"] as? [[String: Any]] ?? []
        let items = data.compactMap(item)
        let total = o["total"] as? Int ?? 0, offset = o["offset"] as? Int ?? 0
        return MangaPage(items: items, hasMore: offset + data.count < total)
    }

    static func title(_ attrs: [String: Any]) -> String {
        let t = attrs["title"] as? [String: String] ?? [:]
        let alts = (attrs["altTitles"] as? [[String: String]] ?? []).reduce(into: [String: String]()) { r, d in for (k, v) in d where r[k] == nil { r[k] = v } }
        for k in ["zh", "zh-hk", "zh-ro"] { if let v = t[k] ?? alts[k], k != "zh-ro" { return v } }
        return t["en"] ?? t["ja-ro"] ?? t.values.first ?? alts["en"] ?? "?"
    }

    static func item(_ d: [String: Any]) -> MangaItem? {
        guard let id = d["id"] as? String, let a = d["attributes"] as? [String: Any] else { return nil }
        // Belt and braces: the query already restricts ratings; drop anything else.
        if let r = a["contentRating"] as? String, r != "safe" && r != "suggestive" { return nil }
        let rels = d["relationships"] as? [[String: Any]] ?? []
        let cover = rels.first { $0["type"] as? String == "cover_art" }.flatMap { ($0["attributes"] as? [String: Any])?["fileName"] as? String }
        let author = rels.first { $0["type"] as? String == "author" }.flatMap { ($0["attributes"] as? [String: Any])?["name"] as? String } ?? ""
        let tags = (a["tags"] as? [[String: Any]] ?? []).compactMap { (($0["attributes"] as? [String: Any])?["name"] as? [String: String])?["en"] }
        return MangaItem(source: .mangadex, mangaId: id, title: title(a),
                         cover: cover.map { "https://uploads.mangadex.org/covers/\(id)/\($0).256.jpg" } ?? "",
                         author: author, tags: Array(tags.prefix(6)), latest: (a["lastChapter"] as? String).map { $0.isEmpty ? "" : "第\($0)话" } ?? "")
    }

    func detail(_ m: MangaItem) async throws -> MangaDetail {
        let o = try await MangaHTTP.json("\(Self.api)/manga/\(m.mangaId)?includes%5B%5D=cover_art&includes%5B%5D=author", headers: Self.headers)
        var it = (o["data"] as? [String: Any]).flatMap(Self.item) ?? m
        if it.cover.isEmpty { it.cover = m.cover }
        let a = (o["data"] as? [String: Any])?["attributes"] as? [String: Any] ?? [:]
        let desc = (a["description"] as? [String: String]).map { $0["zh"] ?? $0["zh-hk"] ?? $0["en"] ?? "" } ?? ""
        var feed: [[String: Any]] = [], off = 0
        repeat {
            let langQ = Self.langs.map { "translatedLanguage%5B%5D=\($0)" }.joined(separator: "&")
            let f = try await MangaHTTP.json("\(Self.api)/manga/\(m.mangaId)/feed?limit=500&offset=\(off)&\(langQ)&\(Self.ratings)&order%5Bvolume%5D=asc&order%5Bchapter%5D=asc", headers: Self.headers)
            let d = f["data"] as? [[String: Any]] ?? []
            feed += d; off += d.count
            if off >= (f["total"] as? Int ?? 0) || d.isEmpty || off >= 2000 { break }
        } while true
        return MangaDetail(item: it, desc: desc, status: a["status"] as? String ?? "", chapters: Self.chapters(feed))
    }

    /// One entry per chapter number, preferring Chinese; external-only chapters (pages == 0) are skipped.
    static func chapters(_ feed: [[String: Any]]) -> [MangaChapter] {
        var best: [String: (rank: Int, id: String, title: String, num: Double)] = [:]
        for c in feed {
            guard let id = c["id"] as? String, let a = c["attributes"] as? [String: Any], (a["pages"] as? Int ?? 0) > 0,
                  a["externalUrl"] as? String == nil else { continue }
            let ch = a["chapter"] as? String ?? ""
            let lang = a["translatedLanguage"] as? String ?? ""
            let rank = langs.firstIndex(of: lang) ?? 9
            let key = ch.isEmpty ? id : ch
            let t = (a["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let title = (ch.isEmpty ? "单话" : "第\(ch)话") + (t.map { " " + $0 } ?? "") + (lang == "en" ? " (EN)" : "")
            if let cur = best[key], cur.rank <= rank { continue }
            best[key] = (rank, id, title, Double(ch) ?? .greatestFiniteMagnitude)
        }
        return best.values.sorted { $0.num < $1.num }.enumerated().map { MangaChapter(chapterId: $0.element.id, title: $0.element.title, index: $0.offset) }
    }

    func pages(_ m: MangaItem, _ c: MangaChapter) async throws -> [String] {
        let o = try await MangaHTTP.json("\(Self.api)/at-home/server/\(c.chapterId)", headers: Self.headers)
        return Self.parseAtHome(o)
    }

    static func parseAtHome(_ o: [String: Any]) -> [String] {
        guard let base = o["baseUrl"] as? String, let ch = o["chapter"] as? [String: Any], let hash = ch["hash"] as? String else { return [] }
        // dataSaver (compressed JPEG/WebP) keeps mobile data use sane.
        if let files = ch["dataSaver"] as? [String], !files.isEmpty { return files.map { "\(base)/data-saver/\(hash)/\($0)" } }
        return (ch["data"] as? [String] ?? []).map { "\(base)/data/\(hash)/\($0)" }
    }
}
